#!/usr/bin/env bash
# =============================================================================
# Offboard a single-project CDR deployment, in the HLD §4.5 removal order:
#
#   1. delete the sink(s) FIRST         (stops new logs flowing), and confirm they are gone
#   2. DRAIN: wait with the collector + push subscription STILL UP, so the in-flight backlog is
#      processed rather than discarded — this same wait also lets sink deletion propagate
#   3. delete the push subscription     (backlog now drained)
#   4. delete the Cloud Run collector + its service accounts
#   5. delete the access-key secret
#   6. delete topics (main + DLQ) + DLQ subscription LAST — only after sink deletion has propagated,
#      or deleting the topic too soon makes Cloud Logging email the project owner an alarming
#      "topic_not_found — logs are not being routed" notice
#   7. revoke the per-tenant API key  ← done in the ARMO backend, NOT here
#   8. mark the cloud_account / CADR feature removed ← ARMO backend
#
# The native Admin Activity audit log is NEVER deleted — only routing stops.
#
# This ordered script is the RECOMMENDED offboarding path (it enforces the §4.5
# drain + propagation waits). `terraform destroy` also removes everything but does
# NOT guarantee that ordering — fine for a test/dormant project, not a live one.
#
# SCOPES. --project alone offboards an ACCOUNT-level connection (project sink).
# For an ORGANIZATION-level connection also pass --organization-id, so the org
# sink is deleted rather than silently left behind:
#
#   account:  --project my-project
#   org:      --project my-security-project --organization-id 123456789012
#
# --project always names the project holding the topic/subscription/collector: the
# onboarded project at account level, the SECURITY project at org level.
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
NAME_PREFIX="${NAME_PREFIX:-armo-cdr}"
SINK_DRAIN_SECONDS="${SINK_DRAIN_SECONDS:-180}"
# Organization-level offboarding. An org connection's sink is NOT a project sink:
# it lives at the organization and must be deleted with --organization. A
# project-scoped delete simply does not see it, so an org teardown that omits
# --organization-id leaves the sink in place, still routing every covered
# project's audit stream at a topic that is about to be deleted.
ORGANIZATION_ID="${ORGANIZATION_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --drain-seconds) SINK_DRAIN_SECONDS="$2"; shift 2 ;;
    --organization-id) ORGANIZATION_ID="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${PROJECT_ID:?set PROJECT_ID (or --project)}"

SERVICE="${NAME_PREFIX}-collector"
TOPIC="${NAME_PREFIX}-audit"
DLQ_TOPIC="${NAME_PREFIX}-audit-dlq"
SUB="${NAME_PREFIX}-audit-push"
DLQ_SUB="${NAME_PREFIX}-audit-dlq-sub"
SINK="${NAME_PREFIX}-activity-sink"
RUNTIME_SA="${NAME_PREFIX}-run"
PUSHER_SA="${NAME_PREFIX}-push"
SECRET="${NAME_PREFIX}-access-key"

gcloud config set project "$PROJECT_ID" >/dev/null

# Build the list of sink scopes to delete. Exactly mirrors what the deploy created:
#   account level -> one project sink
#   org level     -> one organization sink
# Each entry is a gcloud scope flag, applied to the same sink NAME (the deploy uses
# one name across scopes).
SINK_SCOPES=()
if [[ -n "$ORGANIZATION_ID" ]]; then
  SINK_SCOPES+=("--organization=$ORGANIZATION_ID")
else
  SINK_SCOPES+=("--project=$PROJECT_ID")
fi

echo "== 1. Delete the Log Router sink(s) FIRST (stops new logs flowing) =="
echo "     scope(s): ${SINK_SCOPES[*]}"
for scope in "${SINK_SCOPES[@]}"; do
  gcloud logging sinks delete "$SINK" "$scope" --quiet 2>/dev/null || echo "  no sink $SINK at $scope"
done
# Confirm every scope is actually clear before draining: a sink that survives keeps
# publishing into a topic we are about to delete, which is exactly what triggers
# Google's alarming "topic_not_found" email to the project owner.
for scope in "${SINK_SCOPES[@]}"; do
  confirmed=false
  for i in $(seq 1 15); do
    if ! gcloud logging sinks describe "$SINK" "$scope" >/dev/null 2>&1; then
      echo "  sink at $scope confirmed gone"; confirmed=true; break
    fi
    sleep 2
  done
  # If a sink survives the retries, ABORT before the drain + topic deletion: proceeding is exactly the
  # "topic_not_found" owner-email scenario this ordering exists to avoid. Re-run once the sink is gone.
  if [ "$confirmed" != true ]; then
    echo "ERROR: sink $SINK at $scope is still present after ~30s; aborting before topic deletion to avoid the 'topic_not_found' owner email." >&2
    exit 1
  fi
done

echo "== 2. DRAIN: wait ${SINK_DRAIN_SECONDS}s with the collector + subscription STILL UP =="
echo "     HLD §4.5: no new logs arrive (sink deleted), so the collector finishes the"
echo "     in-flight backlog instead of us discarding it by deleting the subscription"
echo "     early. This same wait also lets sink deletion propagate before we remove the"
echo "     topic (skipping it triggers Google's 'topic_not_found' owner email)."
echo "     Set --drain-seconds 0 to skip (e.g. a known-dormant test project)."
_end=$((SECONDS + SINK_DRAIN_SECONDS))
while [ $SECONDS -lt $_end ]; do sleep 5; done

echo "== 3. Delete the push subscription (backlog now drained) =="
gcloud pubsub subscriptions delete "$SUB" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no sub $SUB"

echo "== 4. Delete the Cloud Run service =="
gcloud run services delete "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no service $SERVICE"

echo "== 5. Delete the service accounts =="
for sa in "$RUNTIME_SA" "$PUSHER_SA"; do
  gcloud iam service-accounts delete "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no SA $sa"
done

echo "== 6. Delete the access-key secret =="
gcloud secrets delete "$SECRET" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no secret $SECRET"

echo "== 7. Delete topics + DLQ subscription (sink long gone → no topic_not_found) =="
gcloud pubsub subscriptions delete "$DLQ_SUB" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no sub $DLQ_SUB"
gcloud pubsub topics delete "$TOPIC"     --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no topic $TOPIC"
gcloud pubsub topics delete "$DLQ_TOPIC" --project "$PROJECT_ID" --quiet 2>/dev/null || echo "  no topic $DLQ_TOPIC"

echo
echo "== Verification — anything left? =="
echo "-- sinks:"
for scope in "${SINK_SCOPES[@]}"; do
  gcloud logging sinks list "$scope" --format='value(name)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none at $scope"
done
echo "-- topics:";        gcloud pubsub topics list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none"
echo "-- subscriptions:"; gcloud pubsub subscriptions list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none"
echo "-- cloud run:";     gcloud run services list --project "$PROJECT_ID" --region "$REGION" --format='value(metadata.name)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none"
echo "-- service accts:"; gcloud iam service-accounts list --project "$PROJECT_ID" --format='value(email)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none"
echo "-- secrets:";       gcloud secrets list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep "$NAME_PREFIX" || echo "   none"

cat <<EOF

Infra removed from $PROJECT_ID. Still to do in the ARMO backend (not this script):
  - revoke the per-tenant API key
  - mark the cloud_account / CADR feature removed
The Admin Activity audit log itself was never touched — only routing stopped.
EOF
