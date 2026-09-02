# =============================================================================
# "Deploy to GCP" — organization level (FR-O7 / HLD §4.2)
#
#   Admin Activity logs, every project in the organization
#     └─▶ aggregated org sink  (include_children)   ─┐   (this file)
#                                                    ▼
#         Pub/Sub topic ─▶ OIDC push sub ─▶ Cloud Run collector   (module)
#              (all inside the SECURITY project)
#
# Coverage is ALWAYS whole-organization: one aggregated org sink with
# include_children. Scope is NOT narrowed here — excluded projects are dropped
# server-side at ingestion by the backend's account exclude list (matched on the
# event's project id), never by omitting a sink. See ADR 0016.
#
# The scope-independent core lives in the collector-stack module — the same one
# the single-project root uses. This root adds only the org log sink, whose
# resource type, scope argument and writer-identity shape differ from a project
# sink.
# =============================================================================

module "collector" {
  source = "../modules/collector-stack"

  # The collector stack lives in the security project, NOT in the onboarded
  # projects: one central collector consumes one topic that the aggregated sink
  # fans every covered project's logs into.
  project_id          = var.security_project
  region              = var.region
  collector_image_ref = var.collector_image_ref
  customer_guid       = var.customer_guid
  access_key          = var.access_key
  alert_export_url    = var.alert_export_url
  rule_endpoint_url   = var.rule_endpoint_url
  min_instances       = var.min_instances
  max_instances       = var.max_instances
  name_prefix         = var.name_prefix
  heartbeat_interval  = var.heartbeat_interval

  # LOAD-BEARING for org level. A GCP audit record carries only
  # resource.labels.project_id and no org/folder ancestry, so the collector cannot
  # derive the organization from an event the way the Azure collector reads the
  # tenant off an Activity Log record. Passing them here is the only way the
  # collector can stamp OrgID, and the only way the ingester keys keep-alive on
  # the organization rather than on the security project.
  connection_level = "organization"
  organization_id  = var.organization_id
}

locals {
  # Admin Activity only (HLD §3.2): always on, free, non-deletable. Data Access
  # logs are deliberately out of scope (high-volume, opt-in — FR-C2).
  sink_filter = "logName:\"logs/cloudaudit.googleapis.com%2Factivity\""

  destination = "pubsub.googleapis.com/projects/${var.security_project}/topics/${module.collector.topic_name}"
}

# ---- Log Router sink: whole organization ------------------------------------
# include_children=true is the load-bearing flag: POC-verified by A/B, with it OFF
# a child project's events did NOT arrive (0) and with it ON the same events did.
# It also covers projects created LATER, with no re-onboarding — the FR-O7
# headline.
resource "google_logging_organization_sink" "activity" {
  name             = "${var.name_prefix}-activity-sink"
  org_id           = var.organization_id
  destination      = local.destination
  filter           = local.sink_filter
  include_children = true
}

# ---- Grant the sink's writer identity publisher on the topic -----------------
# THE SILENT-FAILURE TRAP. A sink's writer identity has a DIFFERENT shape per
# scope:
#
#   project → service-<PROJECT_NUMBER>@gcp-sa-logging.iam.gserviceaccount.com
#   org     → service-org-<ORG_ID>@gcp-sa-logging.iam.gserviceaccount.com
#
# Granting the wrong shape fails SILENTLY — no error, simply no logs ever arrive,
# and GCP's own sink metrics do not report it either (POC: exports/error_count
# stayed empty through ~11 dropped entries). Reading the sink's exported
# writer_identity rather than constructing the string is what makes this
# impossible to get wrong. The identity does not exist until the sink is created,
# so it cannot be pre-created; ordering is topic (module) → sink → grant.
resource "google_pubsub_topic_iam_member" "org_sink_writer" {
  project = var.security_project
  topic   = module.collector.topic_name
  role    = "roles/pubsub.publisher"
  member  = google_logging_organization_sink.activity.writer_identity
}

# ---- State moves: the org sink + its grant were previously count-gated -------
# The whole-org sink and its publisher grant used to be `count`-gated on
# scope_is_whole_org, so a live whole-org connection holds them at address
# `[0]`. Dropping the count changed the address to the unindexed resource; these
# moved blocks let `terraform apply` re-key in place instead of destroy+recreate
# (which would briefly stop log routing). No-op when nothing is in state.
moved {
  from = google_logging_organization_sink.activity[0]
  to   = google_logging_organization_sink.activity
}

moved {
  from = google_pubsub_topic_iam_member.org_sink_writer[0]
  to   = google_pubsub_topic_iam_member.org_sink_writer
}

# ---- D2 connectivity check (retried) — HLD §4.4 -----------------------------
# Same probe as the single-project root: force a real label change on ARMO's OWN
# topic, creating no new resource and no new identity in the customer's estate.
# That UpdateTopic is itself an Admin Activity event in the security project, so it
# traverses the pipe and proves it end-to-end.
#
# NOTE: the security project must be in scope for this to work. Under whole-org
# coverage it always is (the org sink covers every child project), so the probe
# event is always routed.
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
        --project "${var.security_project}" \
        --topic   "${module.collector.topic_name}" \
        --attempts ${var.connectivity_check_attempts} \
        --interval ${var.connectivity_check_interval_seconds}
    EOT
  }

  # Only fire once the whole pipe — including the sink→topic grant — is in place.
  depends_on = [
    module.collector,
    google_pubsub_topic_iam_member.org_sink_writer,
  ]
}
