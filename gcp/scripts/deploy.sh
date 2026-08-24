#!/usr/bin/env bash
# =============================================================================
# "Deploy to GCP" — single-project CDR onboarding via gcloud (HLD §4.1, SUB-7814).
#
# The imperative sibling of terraform/single-project. Stands up the full pipe in
# ONE onboarded project:
#
#   Cloud Audit Logs (Admin Activity)
#     └─▶ Log Router sink ─▶ Pub/Sub topic
#           └─▶ OIDC push subscription ─▶ Cloud Run collector (--no-allow-unauthenticated)
#                                            └─▶ pushes only matched alerts ─▶ ARMO
#
# Hardened from the POC (deploy/setup.sh) for production:
#   - always-on min-instances=1, NO Cloud Scheduler (OQ-GCP-6 resolved)
#   - the api key goes into Secret Manager and is mounted as a secret env var,
#     never passed as a plaintext --set-env-vars value
#   - adds the managed rule-delivery endpoint (FR-D5)
#   - fires the retried D2 connectivity check at the end
#
# Idempotent-ish: re-running skips resources that already exist.
#
# Requires: gcloud (authenticated), and on the target project: owner/editor +
# roles/iam.serviceAccountAdmin, plus roles/logging.configWriter to create the sink.
# =============================================================================
set -euo pipefail

# create_idempotent "<human name>" <gcloud create command...>
# Runs a resource-creation command idempotently: it tolerates an "already exists" error (re-runs are
# safe) but ABORTS on any other failure — expired auth, permission denied, quota, API not enabled.
# This replaces the older `<cmd> 2>/dev/null || echo "... exists"` pattern, which swallowed EVERY
# error uniformly: under `set -euo pipefail` the `||` stopped the script aborting on a genuine
# failure, so it could print a false "exists" and run on to a "Pipe is up" success banner with a
# resource actually missing.
create_idempotent() {
  local what="$1"; shift
  local err
  if err="$("$@" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$err" | grep -qiE 'already exists|ALREADY_EXISTS'; then
    echo "  $what exists"
    return 0
  fi
  echo "ERROR creating ${what}:" >&2
  printf '%s\n' "$err" >&2
  return 1
}

# ---- G0 contract inputs (env or flags) --------------------------------------
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
CUSTOMER_GUID="${CUSTOMER_GUID:-}"
ACCESS_KEY="${ACCESS_KEY:-}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-}"
ALERT_EXPORT_URL="${ALERT_EXPORT_URL:-https://report.armo.cloud/cloud/v1/cdrAlert}"
RULES_ENDPOINT_URL="${RULES_ENDPOINT_URL:-https://report.armo.cloud/cloud/v1/cdrRules}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"
MAX_INSTANCES="${MAX_INSTANCES:-3}"
NAME_PREFIX="${NAME_PREFIX:-armo-cdr}"
RUN_CONNECTIVITY_CHECK="${RUN_CONNECTIVITY_CHECK:-true}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
# This script provisions a PROJECT sink, so the scope it onboards is a single
# project and the collector must say so. The flags exist because the collector
# reads them regardless of which path deployed it, and because the backend's
# generated gcloud command passes them — keep the flag names in lockstep with
# cadashboardbe's renderGcpGcloudCommand, whose parser aborts on an unknown flag.
CONNECTION_LEVEL="${CONNECTION_LEVEL:-account}"
ORGANIZATION_ID="${ORGANIZATION_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --customer-guid) CUSTOMER_GUID="$2"; shift 2 ;;
    --access-key) ACCESS_KEY="$2"; shift 2 ;;
    --image) COLLECTOR_IMAGE="$2"; shift 2 ;;
    --alert-export-url) ALERT_EXPORT_URL="$2"; shift 2 ;;
    --rules-url) RULES_ENDPOINT_URL="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --connection-level) CONNECTION_LEVEL="$2"; shift 2 ;;
    --organization-id) ORGANIZATION_ID="$2"; shift 2 ;;
    --heartbeat-interval) HEARTBEAT_INTERVAL="$2"; shift 2 ;;
    --no-connectivity-check) RUN_CONNECTIVITY_CHECK="false"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${PROJECT_ID:?set PROJECT_ID (or --project)}"
: "${CUSTOMER_GUID:?set CUSTOMER_GUID (or --customer-guid) — the ARMO tenant GUID}"
: "${ACCESS_KEY:?set ACCESS_KEY (or --access-key) — the per-tenant API key}"
: "${COLLECTOR_IMAGE:?set COLLECTOR_IMAGE (or --image) — the G4/SUB-7813 collector image ref}"

case "$CONNECTION_LEVEL" in
  account) ;;
  organization)
    # Hard-fail, as the surrounding comment always claimed but the code did not do:
    # it warned and carried on, which would deploy a collector configured to report
    # org-level while only a PROJECT sink exists. That connection can never see the
    # other projects, and its teardown would need org scopes this script never
    # created — a half-connection that looks deployed and is not.
    #
    # An organization connection needs an aggregated org (or per-folder) sink, whose
    # writer identity has a different shape entirely and which this path does not
    # create. There is no gcloud equivalent by design: the backend's
    # renderGcpGcloudCommand also returns "" for an org connection.
    echo "ERROR: --connection-level organization is not supported by this script." >&2
    echo "       It creates a PROJECT sink only; an org connection needs the aggregated" >&2
    echo "       org/folder sinks. Use the Terraform org root instead:" >&2
    echo "         cd gcp/terraform/organization && terraform apply" >&2
    exit 2
    ;;
  *) echo "invalid --connection-level '$CONNECTION_LEVEL': want 'account' or 'organization'" >&2; exit 2 ;;
esac

# Derived names (keep SA ids <= 30 chars).
SERVICE="${NAME_PREFIX}-collector"
TOPIC="${NAME_PREFIX}-audit"
DLQ_TOPIC="${NAME_PREFIX}-audit-dlq"
SUB="${NAME_PREFIX}-audit-push"
DLQ_SUB="${NAME_PREFIX}-audit-dlq-sub"
SINK="${NAME_PREFIX}-activity-sink"
RUNTIME_SA="${NAME_PREFIX}-run"
PUSHER_SA="${NAME_PREFIX}-push"
SECRET="${NAME_PREFIX}-access-key"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "== 0. Enable APIs (HLD §4.1) =="
gcloud services enable \
  run.googleapis.com pubsub.googleapis.com logging.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com \
  --project "$PROJECT_ID"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
PUBSUB_AGENT="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
RUNTIME_SA_EMAIL="${RUNTIME_SA}@${PROJECT_ID}.iam.gserviceaccount.com"
PUSHER_SA_EMAIL="${PUSHER_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "== 1. Pub/Sub topics (main + DLQ) =="
create_idempotent "topic $TOPIC"     gcloud pubsub topics create "$TOPIC"     --project "$PROJECT_ID"
create_idempotent "topic $DLQ_TOPIC" gcloud pubsub topics create "$DLQ_TOPIC" --project "$PROJECT_ID"

echo "== 2. Service accounts (least privilege) =="
create_idempotent "$RUNTIME_SA" gcloud iam service-accounts create "$RUNTIME_SA" --display-name "ARMO CDR collector runtime" --project "$PROJECT_ID"
create_idempotent "$PUSHER_SA"  gcloud iam service-accounts create "$PUSHER_SA"  --display-name "ARMO CDR Pub/Sub push (OIDC)" --project "$PROJECT_ID"
# POC gotcha: a freshly-created SA is not immediately bindable (~4s). Settle.
echo "   waiting for SAs to become bindable (POC: ~4s → 'does not exist' otherwise)"
sleep 10

echo "== 3. Store the api key in Secret Manager (never a plaintext env var) =="
if ! gcloud secrets describe "$SECRET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET" --replication-policy=automatic --project "$PROJECT_ID"
fi
SECRET_VERSION="$(printf '%s' "$ACCESS_KEY" | gcloud secrets versions add "$SECRET" --data-file=- --project "$PROJECT_ID" --format='value(name)')"
SECRET_VERSION="${SECRET_VERSION##*/}"   # pin the concrete version so a rotation forces a new Cloud Run revision
# Runtime SA's SOLE standing grant: read this one secret.
gcloud secrets add-iam-policy-binding "$SECRET" \
  --member "serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role roles/secretmanager.secretAccessor --project "$PROJECT_ID" >/dev/null

echo "== 4. Deploy the private Cloud Run collector (always-on) =="
# --no-allow-unauthenticated: the OIDC ingress gate (HLD §3.3). The api key is
# mounted from Secret Manager via --set-secrets; only non-secret config is env.
gcloud run deploy "$SERVICE" \
  --image "$COLLECTOR_IMAGE" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --service-account "$RUNTIME_SA_EMAIL" \
  --min-instances "$MIN_INSTANCES" \
  --max-instances "$MAX_INSTANCES" \
  --no-cpu-throttling \
  --set-env-vars "ARMO_CUSTOMER_GUID=${CUSTOMER_GUID},ARMO_ALERT_URL=${ALERT_EXPORT_URL},ARMO_RULE_ENDPOINT_URL=${RULES_ENDPOINT_URL},GCP_PROJECT_ID=${PROJECT_ID},GCP_REGION=${REGION},CONNECTION_LEVEL=${CONNECTION_LEVEL},GCP_ORGANIZATION_ID=${ORGANIZATION_ID},HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL}" \
  --set-secrets "ARMO_ACCESS_KEY=${SECRET}:${SECRET_VERSION}" \
  --project "$PROJECT_ID"
SERVICE_URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)' --project "$PROJECT_ID")"
echo "   collector URL: $SERVICE_URL (private)"

echo "== 5. OIDC push auth: pusher SA gets run.invoker; Pub/Sub agent gets token-creator =="
gcloud run services add-iam-policy-binding "$SERVICE" \
  --member "serviceAccount:${PUSHER_SA_EMAIL}" --role roles/run.invoker \
  --region "$REGION" --project "$PROJECT_ID" >/dev/null
# Pub/Sub service agent must be allowed to MINT OIDC tokens for the pusher SA
# (POC finding 7 — missing from the original HLD §5 matrix). Scoped to the pusher
# SA specifically (least privilege), NOT project-wide.
gcloud iam service-accounts add-iam-policy-binding "$PUSHER_SA_EMAIL" \
  --member "$PUBSUB_AGENT" --role roles/iam.serviceAccountTokenCreator --project "$PROJECT_ID" >/dev/null

echo "== 6. DLQ wiring (else dead-lettering silently fails) =="
gcloud pubsub topics add-iam-policy-binding "$DLQ_TOPIC" \
  --member "$PUBSUB_AGENT" --role roles/pubsub.publisher --project "$PROJECT_ID" >/dev/null
# A DLQ topic with NO subscription retains NOTHING (Pub/Sub discards messages to a
# subscriber-less topic) — give it a subscriber or dead-lettered events are lost.
# --expiration-period=never: a DLQ sub sees no traffic by design, so the default
# 31-day inactivity expiry would auto-delete it → DLQ topic becomes subscriber-less
# → dead-lettered events silently discarded again.
create_idempotent "$DLQ_SUB" gcloud pubsub subscriptions create "$DLQ_SUB" --topic "$DLQ_TOPIC" \
  --message-retention-duration 7d --expiration-period=never --project "$PROJECT_ID"

echo "== 7. OIDC push subscription (ack=60s, LOAD-BEARING retry policy, DLQ) =="
# The retry policy is load-bearing: without it Pub/Sub burns max-delivery-attempts
# in SECONDS and a ~30s blip permanently dead-letters real events (POC-measured).
create_idempotent "subscription $SUB" gcloud pubsub subscriptions create "$SUB" \
  --topic "$TOPIC" \
  --push-endpoint "${SERVICE_URL}/" \
  --push-auth-service-account "$PUSHER_SA_EMAIL" \
  --push-auth-token-audience "$SERVICE_URL" \
  --ack-deadline 60 \
  --min-retry-delay 10s \
  --max-retry-delay 600s \
  --dead-letter-topic "$DLQ_TOPIC" \
  --max-delivery-attempts 20 \
  --expiration-period=never \
  --project "$PROJECT_ID"
gcloud pubsub subscriptions add-iam-policy-binding "$SUB" \
  --member "$PUBSUB_AGENT" --role roles/pubsub.subscriber --project "$PROJECT_ID" >/dev/null

echo "== 8. Log Router sink (Admin Activity only) → grant writer publisher on topic =="
# writer identity is generated AT sink creation: order is topic → sink → grant.
create_idempotent "sink $SINK" gcloud logging sinks create "$SINK" \
  "pubsub.googleapis.com/projects/${PROJECT_ID}/topics/${TOPIC}" \
  --log-filter='logName:"logs/cloudaudit.googleapis.com%2Factivity"' \
  --project "$PROJECT_ID"
WRITER="$(gcloud logging sinks describe "$SINK" --project "$PROJECT_ID" --format='value(writerIdentity)')"
echo "   sink writer identity: $WRITER"
gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
  --member "$WRITER" --role roles/pubsub.publisher --project "$PROJECT_ID" >/dev/null

echo
echo "== Pipe is up in $PROJECT_ID =="

if [[ "$RUN_CONNECTIVITY_CHECK" == "true" ]]; then
  echo "== 9. D2 connectivity check (retried) =="
  bash "${HERE}/connectivity-check.sh" --project "$PROJECT_ID" --topic "$TOPIC"
else
  echo "(connectivity check skipped — run: bash ${HERE}/connectivity-check.sh --project $PROJECT_ID --topic $TOPIC)"
fi

cat <<EOF

=========================================================================
Done. Single-project CDR pipe deployed to $PROJECT_ID.

  collector : $SERVICE_URL   (private — only the pusher SA may invoke)
  min-inst  : $MIN_INSTANCES (always-on; emits its own keep-alive, no scheduler)

The account should reach Connected within ~2–4 min, on the first collector
heartbeat. The collector reports a logsSeen count on every heartbeat; the
stronger logsSeen-gated flip (Connected only once a log has provably traversed
the pipe) is pending on the backend side. Watch the logs:
  gcloud run services logs read $SERVICE --region $REGION --project $PROJECT_ID

Tear down (HLD §4.5 order): bash ${HERE}/teardown.sh --project $PROJECT_ID
=========================================================================
EOF
