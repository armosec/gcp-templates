output "collector_url" {
  value       = module.collector.collector_url
  description = "Private Cloud Run collector URL (only the pusher SA may invoke)."
}

output "topic_id" {
  value       = module.collector.topic_id
  description = "Audit Pub/Sub topic the sink publishes to."
}

output "sink_writer_identity" {
  value       = google_logging_project_sink.activity.writer_identity
  description = "Auto-created sink SA granted pubsub.publisher on the topic (project-scoped shape: service-<PROJECT_NUMBER>@gcp-sa-logging...)."
}

output "runtime_service_account" {
  value       = module.collector.runtime_service_account
  description = "Least-privilege collector identity."
}

output "pusher_service_account" {
  value       = module.collector.pusher_service_account
  description = "OIDC pusher identity (run.invoker only)."
}

output "subscription_name" {
  value       = module.collector.subscription_name
  description = "OIDC push subscription name (CADRGcpConfig.PubSubSubscription)."
}

output "next_steps" {
  value = <<-EOT
    CDR pipe is up in project ${var.project_id}.

    ${var.run_connectivity_check ?
  "The retried connectivity check fired during apply — the account should reach Connected within ~2–4 min (on the first collector heartbeat)." :
"Connectivity check was skipped. Run it manually so onboarding completes deterministically:\n      bash scripts/connectivity-check.sh --project ${var.project_id} --topic ${module.collector.topic_name}"}

    Verify:
      gcloud run services logs read ${module.collector.collector_service_name} --region ${var.region} --project ${var.project_id}

    Tear down — prefer the ordered gcloud script (drains in-flight, HLD §4.5):
      bash scripts/teardown.sh --project ${var.project_id}
    (terraform destroy also works but does NOT guarantee drain ordering — fine for
     a test/dormant project, not a live one.)
  EOT
description = "Post-deploy guidance."
}
