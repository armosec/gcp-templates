#!/usr/bin/env bash
# =============================================================================
# D2 connectivity check (HLD §4.4, OQ-GCP-7 resolved 2026-07-27 → option D2).
#
# Fires a RETRIED connectivity-check event so a qualifying Admin Activity log
# traverses  sink → Pub/Sub → collector  within ~2–4 min, even in a completely
# dormant project. The backend flips the account Pending → Connected on the first
# collector heartbeat (a periodic empty-body alert); this check's job is to ensure a
# real log ALSO reaches the collector soon after deploy — it exercises the log pipe
# (and feeds the logsSeen-gated flip planned for GA, OQ-GCP-7).
#
# WHY A FORCED LABEL CHANGE ON ARMO's OWN TOPIC (D2, not D1):
#   - The mutation `google.pubsub.v1.Publisher.UpdateTopic` is itself an Admin
#     Activity event (POC-validated: synchronous, carries principalEmail +
#     resourceName), so it exercises the real pipe.
#   - It touches only a resource the ARMO module already created — it creates NO
#     new resource and NO new identity in the customer's project, so it is far
#     less likely to trip the customer's own SOC than D1 (which creates a
#     throwaway SA). The one audit entry it leaves IS the test — unavoidable and
#     benign.
#
# TWO HARD-WON POC CAVEATS baked in below:
#   (a) THE RETRY IS MANDATORY. A single check fired at T+0 (right after sink
#       creation) is LOST — it lands inside the ~2-min sink-activation window
#       (§3.3). The SAME check at T+127s was delivered. So we fire several
#       attempts spread across the window; at least one lands after activation.
#   (b) EACH ATTEMPT MUST BE A GENUINE MUTATION, never an idempotent no-op.
#       Re-applying an unchanged value emitted an audit entry only 1 of 3 times
#       (a change that changes nothing may produce no audit event). So every
#       attempt sets the label to a NEW value.
#
# This script is the single source of truth for the probe; the Terraform root
# invokes it via local-exec, and deploy.sh calls it too.
# =============================================================================
set -euo pipefail

PROJECT_ID=""
TOPIC=""
ATTEMPTS=8
INTERVAL=30
LABEL_KEY="armo-cdr-connectivity-check"

usage() {
  cat <<'USAGE'
Usage: connectivity-check.sh --project <id> --topic <name> [--attempts N] [--interval SECONDS]

  --project   Project that owns the topic (the onboarded / security project).
  --topic     The ARMO-created Pub/Sub audit topic to mutate (module output topic_name).
  --attempts  Number of forced-mutation probe events to fire (default 8).
  --interval  Seconds between attempts (default 30). 8 × 30s ≈ 4 min.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)  PROJECT_ID="$2"; shift 2 ;;
    --topic)    TOPIC="$2";      shift 2 ;;
    --attempts) ATTEMPTS="$2";   shift 2 ;;
    --interval) INTERVAL="$2";   shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

: "${PROJECT_ID:?--project is required}"
: "${TOPIC:?--topic is required}"

command -v gcloud >/dev/null || { echo "ERROR: gcloud CLI not found on PATH." >&2; exit 1; }

# Remove the marker label on ANY exit (incl. Ctrl-C / timeout) so an aborted run
# never leaves label drift on the Terraform-managed audit topic.
cleanup() { gcloud pubsub topics update "$TOPIC" --remove-labels "$LABEL_KEY" --project "$PROJECT_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "== D2 connectivity check =="
echo "   project : $PROJECT_ID"
echo "   topic   : $TOPIC"
echo "   plan    : $ATTEMPTS attempts, ${INTERVAL}s apart (~$(( ATTEMPTS * INTERVAL / 60 )) min budget)"
echo "   The RETRY is mandatory: a T+0 check is lost to the sink-activation window (§3.3)."
echo

for i in $(seq 1 "$ATTEMPTS"); do
  # A NEW value every attempt — an idempotent no-op may emit no audit event (caveat b).
  VALUE="probe-${i}-$(date -u +%s)"
  echo "$(date -u +%H:%M:%SZ)  attempt ${i}/${ATTEMPTS}: UpdateTopic ${LABEL_KEY}=${VALUE}"

  # `topics update --update-labels` performs UpdateTopic → one Admin Activity entry.
  if gcloud pubsub topics update "$TOPIC" \
       --update-labels "${LABEL_KEY}=${VALUE}" \
       --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "                emitted (google.pubsub.v1.Publisher.UpdateTopic)"
  else
    echo "                WARN: UpdateTopic failed this attempt (will retry)" >&2
  fi

  if [[ "$i" -lt "$ATTEMPTS" ]]; then
    sleep "$INTERVAL"
  fi
done

# (the marker label is removed by the EXIT trap above — robust against interrupts)

cat <<EOF

Done. ${ATTEMPTS} connectivity-check events emitted over ~$(( (ATTEMPTS-1) * INTERVAL / 60 ))–$(( ATTEMPTS * INTERVAL / 60 )) min.

At least one is expected to land AFTER the sink-activation window, traverse
sink → Pub/Sub → collector, exercising the real log pipe. The account reaches
Connected on the first heartbeat — typically within ~2–4 min of deploy.

This script does NOT poll ARMO for the Connected flip (that is backend state);
watch the account status in the ARMO console, or tail the collector logs:
  gcloud run services logs read <collector> --region <region> --project ${PROJECT_ID}
EOF
