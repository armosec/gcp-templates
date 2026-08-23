# =============================================================================
# "Deploy to GCP" — single project (account-level, FR-O6 / HLD §4.1)
#
#   Admin Activity logs
#     └─▶ google_logging_project_sink  (this file)
#           └─▶ Pub/Sub topic ─▶ OIDC push sub ─▶ Cloud Run collector  (module)
#
# The scope-independent core lives in the collector-stack module. This root adds
# the one thing that is scope-specific — the PROJECT-level Log Router sink — and
# fires the D2 connectivity check.
# =============================================================================

module "collector" {
  source = "../modules/collector-stack"

  project_id          = var.project_id
  region              = var.region
  collector_image_ref = var.collector_image_ref
  customer_guid       = var.customer_guid
  access_key          = var.access_key
  alert_export_url    = var.alert_export_url
  rule_endpoint_url   = var.rule_endpoint_url
  min_instances       = var.min_instances
  name_prefix         = var.name_prefix

  # Account level: this root onboards ONE project, so the collector keys its
  # keep-alive on that project. Stated explicitly rather than leaning on the
  # module default, so the contract is visible at the call site.
  connection_level   = "account"
  heartbeat_interval = var.heartbeat_interval
}

# ---- Log Router sink (project scope, Admin Activity only) -------------------
# HLD §3.2 filter: Admin Activity is always-on, free and non-deletable.
# unique_writer_identity=true gives the sink its OWN dedicated SA, which we grant
# publisher on the topic below. Ordering is topic (module) → sink → grant; the
# writer identity does not exist until the sink is created, so it cannot be
# pre-created (HLD §5, compute-decisions gotcha 2).
resource "google_logging_project_sink" "activity" {
  project     = var.project_id
  name        = "${var.name_prefix}-activity-sink"
  destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${module.collector.topic_name}"
  filter      = "logName:\"logs/cloudaudit.googleapis.com%2Factivity\""

  unique_writer_identity = true
}

# Grant the sink's writer identity publisher on the topic. Expect a brief IAM
# propagation delay before the first log is actually routed on a fresh deploy.
#
# NOTE ON THE SINK-ACTIVATION WINDOW (HLD §3.3): a newly created sink does not
# route immediately (~2 min), and events produced in that window are LOST, not
# queued — and provisioning order cannot fix it (creating the sink --disabled
# then enabling it was measured WORSE). That window is absorbed by the retried
# connectivity check below + the collector's logsSeen gate, NOT engineered away
# here. Do not attempt a disabled-then-enable ordering.
resource "google_pubsub_topic_iam_member" "sink_writer" {
  project = var.project_id
  topic   = module.collector.topic_name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.activity.writer_identity
}

# ---- D2 connectivity check (retried) — HLD §4.4 -----------------------------
# Fire the retried probe so a qualifying Admin Activity log reaches the collector
# within ~2–4 min even in a dormant project. The probe forces a real label change
# on ARMO's OWN topic (created by the module) — creating NO new resource and NO
# new identity in the customer's project (the D2 variant, vs D1). The backend
# flips Pending → Connected on the first collector heartbeat reporting
# logsSeen > 0; this module's job is only to GENERATE the qualifying event(s).
#
# Implemented as a local-exec so `terraform apply` yields a complete onboarding.
# The exact same logic is in scripts/connectivity-check.sh for the gcloud path.
resource "null_resource" "connectivity_check" {
  count = var.run_connectivity_check ? 1 : 0

  # Re-run whenever the pipe identity changes (new topic/collector = re-verify).
  triggers = {
    topic     = module.collector.topic_name
    collector = module.collector.collector_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      "${path.module}/../../scripts/connectivity-check.sh" \
        --project "${var.project_id}" \
        --topic   "${module.collector.topic_name}" \
        --attempts ${var.connectivity_check_attempts} \
        --interval ${var.connectivity_check_interval_seconds}
    EOT
  }

  # Only fire once the whole pipe (incl. the sink→topic grant) is in place.
  depends_on = [
    module.collector,
    google_pubsub_topic_iam_member.sink_writer,
  ]
}
