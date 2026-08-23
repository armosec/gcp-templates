# =============================================================================
# collector-stack — the scope-independent core of the GCP CDR deploy.
#
#   Pub/Sub topic ──(OIDC push sub)──▶ Cloud Run collector (private)
#        ▲                                     │
#        │ (sink writer, granted by caller)    └─▶ pushes only matched alerts ─▶ ARMO
#        │
#   DLQ topic + its own subscription (else dead-lettered events are DISCARDED)
#
# Every non-obvious choice here is a POC-measured finding, cited inline. See
# ../../single-project for how the sink + connectivity check wrap this module.
#
# Block order mirrors the AWS/Azure deploy templates so the three read the same
# top-to-bottom: APIs → data plane → identity → IAM → compute → subscriptions.
# (Terraform resolves references from the dependency graph, not file order.)
# =============================================================================

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # The Pub/Sub service agent — needs token-creator (to mint OIDC tokens for the
  # pusher SA) plus DLQ publisher + subscription subscriber, or dead-lettering
  # silently fails (POC finding 7 / HLD §3.3, §5).
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  names = {
    service      = "${var.name_prefix}-collector"
    topic        = "${var.name_prefix}-audit"
    dlq_topic    = "${var.name_prefix}-audit-dlq"
    subscription = "${var.name_prefix}-audit-push"
    dlq_sub      = "${var.name_prefix}-audit-dlq-sub"
    runtime_sa   = "${var.name_prefix}-run"  # least-priv identity the collector runs as
    pusher_sa    = "${var.name_prefix}-push" # Pub/Sub uses this to OIDC-auth the push
    secret       = "${var.name_prefix}-access-key"
  }
}

# ---- APIs -------------------------------------------------------------------
# The GCP analogue of Azure's microsoft.insights registration (HLD §4.1).
# disable_on_destroy=false so `terraform destroy` never disables a shared API the
# customer relies on for other workloads.
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "logging.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---- Data plane: Pub/Sub topics (main + DLQ) + access-key secret ---------------
resource "google_pubsub_topic" "audit" {
  project    = var.project_id
  name       = local.names.topic
  labels     = var.labels
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "dlq" {
  project    = var.project_id
  name       = local.names.dlq_topic
  labels     = var.labels
  depends_on = [google_project_service.apis]
}

# access-key secret (HLD §3.7 — injected as a Cloud Run secret, never plaintext).
resource "google_secret_manager_secret" "access_key" {
  project   = var.project_id
  secret_id = local.names.secret
  labels    = var.labels
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "access_key" {
  secret      = google_secret_manager_secret.access_key.id
  secret_data = var.access_key
}

# ---- Identity: service accounts (least privilege) ---------------------------
# runtime_sa: the identity the collector runs as. Under PUSH it needs NO
# pubsub.subscriber (Pub/Sub pushes to it) — its ONLY standing grant is
# secretAccessor on the access-key secret (below). This corrects the HLD §5 matrix,
# which showed the pull-model grant (POC finding 7).
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = local.names.runtime_sa
  display_name = "ARMO CDR — Cloud Run collector runtime"
  depends_on   = [google_project_service.apis]
}

# pusher_sa: Pub/Sub attaches a Google-signed OIDC JWT minted for this SA to every
# push; Cloud Run's IAM proxy validates it. Its ONLY grant is run.invoker on the
# service (below) — the least-privilege pusher the acceptance criteria require.
resource "google_service_account" "pusher" {
  project      = var.project_id
  account_id   = local.names.pusher_sa
  display_name = "ARMO CDR — Pub/Sub push (OIDC)"
  depends_on   = [google_project_service.apis]
}

# POC gotcha: a freshly-created SA is not immediately bindable (~4s → "does not
# exist"). Settle before any IAM binding references these SAs, or the first apply
# in a clean project flakes.
resource "time_sleep" "sa_settle" {
  depends_on      = [google_service_account.runtime, google_service_account.pusher]
  create_duration = "10s"
}

# ---- IAM grants -------------------------------------------------------------
# The runtime SA's SOLE standing permission: read this one secret.
resource "google_secret_manager_secret_iam_member" "runtime_reads_key" {
  project    = var.project_id
  secret_id  = google_secret_manager_secret.access_key.secret_id
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${google_service_account.runtime.email}"
  depends_on = [time_sleep.sa_settle]
}

# Pub/Sub service-agent grants (or dead-lettering silently fails).
# Token-creator: mint OIDC tokens for the pusher SA (POC finding 7 — missing from
# the original HLD §5 matrix; without it the push subscription create fails).
# Scoped to the pusher SA specifically (least privilege) — NOT project-wide, so
# the Pub/Sub agent can impersonate only this one SA, not every SA in the project.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pusher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_agent
  depends_on         = [time_sleep.sa_settle]
}

# Publisher on the DLQ: lets Pub/Sub offload poison pills to the dead-letter topic.
resource "google_pubsub_topic_iam_member" "pubsub_agent_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dlq.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

# ---- Compute: Cloud Run collector (private) ---------------------------------
# INGRESS_TRAFFIC_ALL is required — Pub/Sub push originates from Google's managed
# infrastructure over the public internet, not from a VPC, so internal-only
# ingress would black-hole every delivery. The endpoint is NOT public: auth is
# enforced by IAM (--no-allow-unauthenticated equivalent — no allUsers /
# allAuthenticatedUsers binding), so only the pusher SA's OIDC token gets in
# (HLD §3.3). This is the load-bearing anti-forgery control.
resource "google_cloud_run_v2_service" "collector" {
  project             = var.project_id
  name                = local.names.service
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = var.labels

  # organization_id's description calls itself REQUIRED at organization level, but
  # nothing enforced it — the module would happily deploy an org-level collector
  # with no org to stamp. It would then fail at container start (the collector
  # refuses to boot in that state), which is a slow and confusing way to learn about
  # a typo in a tfvars file. A precondition fails it at plan time instead.
  #
  # A variable-level `validation` block cannot express this: cross-variable
  # references in validation need Terraform >= 1.9, and this module supports >= 1.5.
  # Preconditions have been available since 1.2.
  lifecycle {
    precondition {
      condition     = var.connection_level != "organization" || var.organization_id != ""
      error_message = "organization_id is required when connection_level is \"organization\" — the collector has no other source for the org (a GCP audit record carries no org ancestry) and will refuse to start without it."
    }
  }

  template {
    service_account = google_service_account.runtime.email
    scaling {
      # Always-on (OQ-GCP-6): min_instances=1 keeps the collector warm so it emits
      # its own keep-alive cadence with no Cloud Scheduler. Cloud Run autoscales on
      # push volume up to max_instances.
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }
    containers {
      image = var.collector_image_ref
      ports {
        container_port = 8080
      }

      # CPU always allocated (instance-based billing). Cloud Run throttles CPU OUTSIDE
      # request handling by default, so a background keep-alive timer would freeze
      # between pushes and never fire on a quiet project. min_instances=1 keeps the
      # INSTANCE warm but not the CPU — Cloud Run's own docs require BOTH for background
      # work (billing-settings + min-instances). This is the load-bearing half of OQ-GCP-6.
      resources {
        # Explicit limits MUST accompany cpu_idle — a resources block with only cpu_idle
        # is dropped on create, so the setting never reaches the API and the service comes
        # up CPU-throttled (verified on a live apply; cf. terraform-provider-google#17246).
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
        cpu_idle = false
      }

      # ---- G0 CONTRACT: env-var mapping the G4 collector image consumes -------
      # customerGUID / exporter URL / rule endpoint / project / region as plain
      # env; the api key as a SECRET-BACKED env (value_source), never plaintext.
      env {
        name  = "ARMO_CUSTOMER_GUID" # ARMO CustomerGUID (ARMO_-prefixed platform value, shared with Azure)
        value = var.customer_guid
      }
      env {
        name  = "ARMO_ALERT_URL"
        value = var.alert_export_url
      }
      env {
        name  = "ARMO_RULE_ENDPOINT_URL"
        value = var.rule_endpoint_url
      }
      env {
        name  = "GCP_PROJECT_ID" # onboarded scope — feeds CloudMetadata.accountID (SUB-7649) + heartbeat
        value = var.project_id
      }
      env {
        name  = "GCP_REGION"
        value = var.region
      }
      # connection_level tells the ingester which scope to key keep-alive on,
      # rather than inferring the level from whether OrgID happens to be set.
      #
      # On GCP the organization is configuration-driven, not event-derived: an
      # audit record carries only resource.labels.project_id and no org ancestry.
      # At organization level organization_id is required (see the precondition
      # below), so OrgID is always stamped and an empty one is a bug. Stating the
      # level is what keeps that visible: inference would read a missing org id as
      # "account connection" and silently key keep-alive on the security project,
      # which is not an onboarded scope.
      env {
        name  = "CONNECTION_LEVEL"
        value = var.connection_level
      }
      env {
        name  = "GCP_ORGANIZATION_ID" # org-level only; a GCP audit record has no org ancestry to derive it from
        value = var.organization_id
      }
      env {
        name  = "HEARTBEAT_INTERVAL"
        value = var.heartbeat_interval
      }
      env {
        name = "ARMO_ACCESS_KEY" # per-tenant API key — from Secret Manager, not plaintext
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.access_key.secret_id
            version = google_secret_manager_secret_version.access_key.version
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.access_key,
    google_secret_manager_secret_iam_member.runtime_reads_key,
  ]
}

# Private ingress gate: ONLY the pusher SA may invoke. No allUsers binding = the
# endpoint is not a public webhook (HLD §3.3).
resource "google_cloud_run_v2_service_iam_member" "pusher_invoker" {
  project    = var.project_id
  name       = google_cloud_run_v2_service.collector.name
  location   = var.region
  role       = "roles/run.invoker"
  member     = "serviceAccount:${google_service_account.pusher.email}"
  depends_on = [time_sleep.sa_settle]
}

# ---- Subscriptions (push + DLQ) ---------------------------------------------
resource "google_pubsub_subscription" "push" {
  project = var.project_id
  name    = local.names.subscription
  topic   = google_pubsub_topic.audit.name
  labels  = var.labels

  ack_deadline_seconds = var.ack_deadline_seconds

  # LOAD-BEARING (POC-corrected). Without this retry policy Pub/Sub retries
  # immediately and exhausts max_delivery_attempts in SECONDS, so a ~30s collector
  # blip permanently dead-letters real audit events instead of leaving them in the
  # recoverable backlog. Re-measured WITH it: events survived an 8-min outage with
  # zero dead-lettering, all delivered on restore (HLD §3.4).
  retry_policy {
    minimum_backoff = var.retry_minimum_backoff
    maximum_backoff = var.retry_maximum_backoff
  }

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.collector.uri}/"
    oidc_token {
      service_account_email = google_service_account.pusher.email
      audience              = google_cloud_run_v2_service.collector.uri
    }
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  # These must all be in place BEFORE the subscription is created, or the create
  # (and dead-lettering) flakes across applies:
  #   - pusher_invoker: the pusher SA must hold run.invoker or the first push 403s
  #   - pubsub_token_creator: the Pub/Sub agent must be able to mint the OIDC token
  #   - pubsub_agent_dlq_publisher: or dead-lettering to the DLQ silently fails
  depends_on = [
    google_cloud_run_v2_service_iam_member.pusher_invoker,
    google_service_account_iam_member.pubsub_token_creator,
    google_pubsub_topic_iam_member.pubsub_agent_dlq_publisher,
  ]

  # Never expire. A subscription with no expiration_policy auto-deletes after 31
  # days of INACTIVITY — and a dormant project produces no audit events, so the
  # push subscription could silently expire and kill the pipe. An empty ttl pins
  # it forever (HLD §3.4 durability intent).
  expiration_policy {
    ttl = ""
  }
}

# Pub/Sub agent needs subscriber on the push subscription for dead-lettering to work.
resource "google_pubsub_subscription_iam_member" "pubsub_agent_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.push.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# DLQ subscription (MANDATORY). A DLQ topic with NO subscription retains NOTHING —
# Pub/Sub discards messages published to a subscriber-less topic, so dead-lettered
# events would be silently lost, defeating the DLQ entirely (POC finding). This
# subscriber makes poison pills recoverable; production should also alert on it.
resource "google_pubsub_subscription" "dlq" {
  project = var.project_id
  name    = local.names.dlq_sub
  topic   = google_pubsub_topic.dlq.name
  labels  = var.labels

  # Keep poison pills the full 7 days so an operator can inspect them.
  message_retention_duration = "604800s"

  # Never expire (critical): a DLQ subscription sees no traffic by design, so with
  # the default 31-day inactivity expiry it would be auto-deleted → the DLQ topic
  # becomes subscriber-less → all future dead-lettered events are silently
  # discarded, re-creating the exact data-loss the DLQ subscription prevents.
  expiration_policy {
    ttl = ""
  }
}
