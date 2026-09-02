output "collector_url" {
  value       = module.collector.collector_url
  description = "Private Cloud Run collector URL (only the pusher SA may invoke)."
}

output "topic_id" {
  value       = module.collector.topic_id
  description = "Audit Pub/Sub topic every covered project's logs fan into (CADRGcpConfig.PubSubTopic)."
}

output "subscription_name" {
  value       = module.collector.subscription_name
  description = "OIDC push subscription name (CADRGcpConfig.PubSubSubscription)."
}

output "runtime_service_account" {
  value       = module.collector.runtime_service_account
  description = "Least-privilege collector identity (CADRGcpConfig.ServiceAccountEmail)."
}

output "pusher_service_account" {
  value       = module.collector.pusher_service_account
  description = "OIDC pusher identity (CADRGcpConfig.PusherServiceAccountEmail)."
}

output "sink_names" {
  value       = ["organizations/${var.organization_id}/sinks/${google_logging_organization_sink.activity.name}"]
  description = "The org-root sink this connection created. The backend persists it as CADRGcpConfig.LogSinkNames — it is what teardown must delete FIRST (HLD §4.5), and a sink whose name was never recorded cannot be cleaned up."
}

output "sink_writer_identities" {
  value       = [google_logging_organization_sink.activity.writer_identity]
  description = "Auto-created sink SA granted pubsub.publisher on the topic. Org shape is service-org-<ORG_ID>@ — never the project shape."
}

output "coverage" {
  value       = "whole-organization (include_children)"
  description = "What this connection covers: the whole organization. Surfaced explicitly because whole-org coverage duplicates EVERY child project's audit stream into the topic; excluded projects are filtered server-side at ingestion (ADR 0016), not by this module."
}

output "next_steps" {
  value = <<-EOT
    CDR pipe is up for organization ${var.organization_id}.
    Collector + topic live in security project ${var.security_project}.
    Coverage: whole organization, including projects created later (no re-onboarding). Excluded projects are dropped server-side at ingestion (ADR 0016), not here.

    ${var.run_connectivity_check ?
  "The retried connectivity check fired during apply — the organization should reach Connected within ~2–4 min (on the first collector heartbeat)." :
"Connectivity check was skipped. Run it manually so onboarding completes deterministically:\n      bash scripts/connectivity-check.sh --project ${var.security_project} --topic ${module.collector.topic_name}"}
    Verify:
      gcloud run services logs read ${module.collector.collector_service_name} --region ${var.region} --project ${var.security_project}

    Tear down — prefer the ordered gcloud script (deletes sinks first, drains
    in-flight detections, HLD §4.5):
      bash scripts/teardown.sh --project ${var.security_project} --organization-id ${var.organization_id}
    (terraform destroy also works but does NOT guarantee drain ordering — fine for
     a test/dormant organization, not a live one.)
  EOT
description = "Post-deploy guidance."
}
