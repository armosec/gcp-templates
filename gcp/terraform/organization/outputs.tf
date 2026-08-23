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
  value = local.scope_is_whole_org ? [
    for s in google_logging_organization_sink.activity : "organizations/${var.organization_id}/sinks/${s.name}"
    ] : [
    for k, s in google_logging_folder_sink.activity : "folders/${k}/sinks/${s.name}"
  ]
  description = "Every sink this connection created, one per covered scope. The backend persists these as CADRGcpConfig.LogSinkNames — they are what teardown must delete FIRST (HLD §4.5), and a sink whose name was never recorded cannot be cleaned up."
}

output "sink_writer_identities" {
  value = local.scope_is_whole_org ? [
    for s in google_logging_organization_sink.activity : s.writer_identity
    ] : [
    for s in google_logging_folder_sink.activity : s.writer_identity
  ]
  description = "Auto-created sink SAs granted pubsub.publisher on the topic. Org shape is service-org-<ORG_ID>@; folder shape is service-folder-<FOLDER_ID>@ — never the project shape."
}

output "coverage" {
  value       = local.scope_is_whole_org ? "whole-organization (include_children)" : "folders: ${join(", ", local.folder_ids)}"
  description = "What this connection actually covers. Surfaced explicitly because whole-org coverage duplicates EVERY child project's audit stream into the topic, and the sink set is the only containment."
}

output "next_steps" {
  value = <<-EOT
    CDR pipe is up for organization ${var.organization_id}.
    Collector + topic live in security project ${var.security_project}.
    Coverage: ${local.scope_is_whole_org ? "whole organization, including projects created later (no re-onboarding)" : "folders ${join(", ", local.folder_ids)} (and any project added to them later)"}

    ${var.run_connectivity_check ?
  "The retried connectivity check fired during apply — the organization should reach Connected within ~2–4 min (on the first collector heartbeat)." :
"Connectivity check was skipped. Run it manually so onboarding completes deterministically:\n      bash scripts/connectivity-check.sh --project ${var.security_project} --topic ${module.collector.topic_name}"}
    ${local.scope_is_whole_org ? "" : "\n    NOTE (folder scoping): the connectivity check mutates the topic in ${var.security_project}. That only produces a routed event if ${var.security_project} sits inside one of the included folders. If it does not, expect Connected to wait on organic activity in a covered project instead.\n"}
    Verify:
      gcloud run services logs read ${module.collector.collector_service_name} --region ${var.region} --project ${var.security_project}

    Tear down — prefer the ordered gcloud script (deletes sinks first, drains
    in-flight detections, HLD §4.5):
      bash scripts/teardown.sh --project ${var.security_project} --organization-id ${var.organization_id}${local.scope_is_whole_org ? "" : " --include-folders ${join(",", local.folder_ids)}"}
    (terraform destroy also works but does NOT guarantee drain ordering — fine for
     a test/dormant organization, not a live one.)
  EOT
description = "Post-deploy guidance."
}
