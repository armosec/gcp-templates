output "topic_name" {
  value       = google_pubsub_topic.audit.name
  description = "Short name of the audit topic the sink must publish to."
}

output "topic_id" {
  value       = google_pubsub_topic.audit.id
  description = "Full resource id of the audit topic (projects/<p>/topics/<t>)."
}

output "dlq_topic_name" {
  value       = google_pubsub_topic.dlq.name
  description = "Dead-letter topic name."
}

output "collector_service_name" {
  value       = google_cloud_run_v2_service.collector.name
  description = "Cloud Run collector service name."
}

output "collector_url" {
  value       = google_cloud_run_v2_service.collector.uri
  description = "Private Cloud Run URL — only the pusher SA may invoke it (OIDC)."
}

output "runtime_service_account" {
  value       = google_service_account.runtime.email
  description = "Least-privilege collector identity (only secretAccessor on the access-key secret)."
}

output "pusher_service_account" {
  value       = google_service_account.pusher.email
  description = "Pub/Sub OIDC pusher identity (only run.invoker on the collector)."
}

output "subscription_name" {
  value       = google_pubsub_subscription.push.name
  description = "OIDC push subscription name."
}
