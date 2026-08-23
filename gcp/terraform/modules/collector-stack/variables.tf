# -----------------------------------------------------------------------------
# collector-stack — inputs
#
# This module provisions everything the CDR collector needs that is INDEPENDENT
# of the log-source scope (project vs. organization): APIs, the Pub/Sub topic +
# DLQ, the OIDC-authenticated push subscription, the Cloud Run collector, its
# service accounts, the access-key secret, and all the IAM in between.
#
# It deliberately does NOT create the Log Router sink — the sink resource and its
# writer-identity grant differ by scope (project sink vs. org/folder sink, each
# with a different writer-identity shape, HLD §4.2). The caller owns the sink and
# passes the topic on. That seam is what lets the single-project root (this
# ticket, SUB-7814) and the future org root (G6/SUB-7815) share this module.
# -----------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "The project that hosts the collector stack (topic, subscription, Cloud Run). Account-level: the onboarded project itself. Org-level (G6): the designated security project."
}

variable "region" {
  type        = string
  description = "Region for the Cloud Run collector and its resources."
  default     = "us-central1"
}

# ---- G0 interface contract: what the backend injects ------------------------
# These five values are the deploy-time contract between the ARMO backend
# (module/link generation, analogue of AWS GenerateCADRStackLink) and this module.
# They flow into the collector container as environment variables (see main.tf
# for the exact env-var mapping — that mapping IS the contract the G4 collector
# image consumes).

variable "collector_image_ref" {
  type        = string
  description = <<-EOT
    Fully-qualified collector image ref, e.g. quay.io/armosec/cdr-gcp:v0.1.0.
    LEFT AS A PARAMETER ON PURPOSE — the image is built by G4/SUB-7813 and does
    not exist yet. Published to a public registry (HLD §3.5, anonymous pull), so
    the customer needs no credential to pull it.
  EOT
}

variable "customer_guid" {
  type        = string
  description = "ARMO tenant identifier (CustomerGUID). Sent on every alert/heartbeat so the backend can bind the payload to the tenant (FR-A6). Analogue of the AWS template's AccountID param."
}

variable "access_key" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Per-tenant API key minted at onboarding (HLD §3.7). Stored in Secret Manager
    and injected into Cloud Run as a secret-backed env var — never a plaintext
    env value. Sent outbound as the X-API-KEY header to ARMO. There is NO ARMO-held
    GCP secret at rest (CDR is push, HLD §4.3), so this only ever travels one way.
  EOT
}

variable "alert_export_url" {
  type        = string
  description = "ARMO alert-ingest endpoint the collector POSTs CdrAlertBatch to (FR-A1)."
  default     = "https://report.armo.cloud/cloud/v1/cdrAlert"
}

variable "rule_endpoint_url" {
  type        = string
  description = "ARMO managed rule-delivery endpoint the collector fetches the current rule set from (FR-D5, HLD §3.6). New vs. AWS, which bakes rules into the image."
  default     = "https://report.armo.cloud/cloud/v1/cdrRules"
}

# ---- compute / idle model ----------------------------------------------------
variable "min_instances" {
  type        = number
  description = "Cloud Run min instances. Default 1 = always-on (OQ-GCP-6 resolved, HLD §3.4): the collector stays warm and emits its own keep-alive cadence, so NO Cloud Scheduler is needed. Do not set 0 for production."
  default     = 1
}

variable "max_instances" {
  type        = number
  description = "Cloud Run max instances. Control-plane volume is low; a small ceiling is plenty and caps blast radius / cost."
  default     = 3
}

variable "ack_deadline_seconds" {
  type        = number
  description = "Push subscription ack deadline. 60s cushions cold start (POC: 132ms) + synchronous rule refresh (~5s hard cap) + CEL eval, well clear of the deadline so a slow request cannot trigger a redelivery storm (HLD §3.6, compute-decisions)."
  default     = 60
}

# ---- resilience (POC-corrected — the naive config LOSES audit data) ----------
# Defaults below are the POC-validated fix (HLD §3.4). Exposed as variables so
# they are auditable, but the defaults are the tested-safe values — do not lower
# them without re-measuring.
variable "retry_minimum_backoff" {
  type        = string
  description = "Push retry min backoff. LOAD-BEARING: without a retry policy Pub/Sub retries immediately and burns the whole attempt budget in seconds, dead-lettering real events ~30s into any blip (POC-measured)."
  default     = "10s"
}

variable "retry_maximum_backoff" {
  type        = string
  description = "Push retry max backoff. With 10s..600s exponential backoff, 20 attempts span a long window so transient outages recover instead of losing data (POC: survived 8 min outage, zero dead-lettering)."
  default     = "600s"
}

variable "max_delivery_attempts" {
  type        = number
  description = "Deliveries before dead-lettering. Paired with the retry policy above; the retry policy is the load-bearing half."
  default     = 20
}

# ---- naming ------------------------------------------------------------------
# Defaults are stable, self-describing names. Overridable so multiple stacks can
# coexist / for the org security-project variant. Service-account account_ids are
# capped at 30 chars by GCP — these fit with room to spare.
variable "name_prefix" {
  type        = string
  description = "Prefix for all created resource names. Keep short — SA account_ids are capped at 30 chars (POC hit a silent failure at 32)."
  default     = "armo-cdr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphen, start with a letter, and be <= 19 chars (keeps derived SA ids within GCP's 30-char cap)."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to labelable resources (topics, Cloud Run) for cost attribution / inventory."
  default = {
    managed-by = "armo-cdr"
    component  = "cdr-collector"
  }
}

# ---- connection level / heartbeat (G0 contract, org support) -----------------
# These three reach the collector as CONNECTION_LEVEL / GCP_ORGANIZATION_ID /
# HEARTBEAT_INTERVAL. They exist because the ingester routes keep-alive by the
# STATED connection level, not by inferring it from whether an org id is present.
#
# GCP needs them more than Azure does. An Azure Activity Log record carries its
# tenant, so the collector can always name the org above an account. A GCP audit
# record carries only resource.labels.project_id and NO org/folder ancestry, so at
# organization level the org id can only come from configuration — pass it here or
# every org-level batch goes out with an empty OrgID and the ingester keys the
# keep-alive on the wrong scope.
variable "connection_level" {
  type        = string
  description = "Onboarded scope this collector serves: \"account\" (single project) or \"organization\" (aggregated org/folder sink). Stamped on every alert and heartbeat so the ingester routes keep-alive by intent rather than inference."
  default     = "account"

  validation {
    condition     = contains(["account", "organization"], var.connection_level)
    error_message = "connection_level must be \"account\" or \"organization\"."
  }
}

variable "organization_id" {
  type        = string
  description = "Bare numeric organization ID (e.g. \"123456789012\"), REQUIRED when connection_level is \"organization\" and ignored otherwise. Stamped as the batch OrgID; it cannot be derived from a GCP audit record, which carries no org ancestry."
  default     = ""

  validation {
    condition     = var.organization_id == "" || can(regex("^[0-9]{1,20}$", var.organization_id))
    error_message = "organization_id must be a bare numeric ID, without the \"organizations/\" prefix."
  }
}

variable "heartbeat_interval" {
  type        = string
  description = "Liveness heartbeat cadence as a Go duration. Must stay comfortably below the backend's disconnect-staleness threshold (12h for regular accounts) or a quiet-but-healthy project false-disconnects. 5m leaves a wide margin and matches Azure."
  default     = "5m"

  # A malformed Go duration is otherwise not caught until the collector parses it at container
  # start, which is a slow way to learn about a tfvars typo ("5mm", "5min", a bare "30"). Same
  # spirit as the organization_id precondition. RE2 has no backtracking, but it does try every
  # alternative, so multi-unit values like "1h30m" and "500ms" match correctly.
  validation {
    condition     = can(regex("^([0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h))+$", var.heartbeat_interval))
    error_message = "heartbeat_interval must be a Go duration, e.g. \"5m\", \"30s\" or \"1h30m\"."
  }

  # Positive, not merely well-formed: time.NewTicker panics on a non-positive duration, so the
  # collector rejects it too. A positive duration must contain at least one non-zero digit, which
  # catches "0s" and "0h0m" alike without a second grammar.
  validation {
    condition     = length(regexall("[1-9]", var.heartbeat_interval)) > 0
    error_message = "heartbeat_interval must be greater than zero."
  }
}
