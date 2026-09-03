# =============================================================================
# "Deploy to GCP" — organization root module (SUB-7815, HLD §4.2)
#
# THE G0 INTERFACE CONTRACT. These names are NOT free to rename: cadashboardbe's
# renderGcpTerraformModule emits exactly `organization_id`, `security_project`
# and `region` for an org connection, alongside the shared customer_guid /
# collector_image_ref / alert_export_url / rule_endpoint_url / name_prefix /
# access_key. A rename here silently produces a generated artifact that fails to
# apply in the customer's shell. (Coverage is always whole-organization; excluded
# projects are filtered server-side at ingestion, not by this module — ADR 0016.)
# =============================================================================

variable "organization_id" {
  type        = string
  description = "Bare numeric organization ID to onboard (e.g. \"123456789012\"), without the \"organizations/\" prefix — matching how CADRGcpConfig stores it."

  validation {
    condition     = can(regex("^[0-9]{1,20}$", var.organization_id))
    error_message = "organization_id must be a bare numeric ID, without the \"organizations/\" prefix."
  }
}

variable "security_project" {
  type        = string
  description = <<-EOT
    The customer's designated security project. The topic, subscription and Cloud
    Run collector are provisioned HERE, and every covered project's Admin Activity
    logs fan into it cross-project (staying inside the org boundary, PC1).

    It must NOT already carry an account-level CDR connection: both levels derive
    resource names from the same name_prefix, so they would redeploy over each
    other. The backend enforces this (securityProjectHasAccountLevelCADR, 409).
  EOT
}

variable "region" {
  type        = string
  description = "Region for the Cloud Run collector and Pub/Sub resources."
  default     = "us-central1"
}

# ---- shared G0 contract values ----------------------------------------------
variable "collector_image_ref" {
  type        = string
  description = "Fully-qualified collector image ref (e.g. us-docker.pkg.dev/elated-pottery-310110/armosec-public/cdr-gcp:gcp-v0.0.1). Tagged `gcp-v<x.y.z>` by the release pipeline."
}

variable "customer_guid" {
  type        = string
  description = "ARMO tenant identifier (CustomerGUID)."
}

variable "access_key" {
  type        = string
  sensitive   = true
  description = "Per-tenant API key minted at onboarding. Stored in Secret Manager and injected into Cloud Run as a secret. Never committed — pass via a generated tfvars, TF_VAR_access_key, or -var."
}

variable "alert_export_url" {
  type        = string
  description = "ARMO alert-ingest endpoint (FR-A1)."
  default     = "https://report.armo.cloud/cloud/v1/cdrAlert"
}

variable "rule_endpoint_url" {
  type        = string
  description = "ARMO managed rule-delivery endpoint (FR-D5)."
  default     = "https://report.armo.cloud/cloud/v1/cdrRules"
}

variable "min_instances" {
  type        = number
  description = "Cloud Run min instances. 1 = always-on (OQ-GCP-6). Do not set 0 in production."
  default     = 1
}

variable "max_instances" {
  type        = number
  description = "Cloud Run max instances. An org-level collector fans in every covered project, so it sees more volume than a single-project one — the ceiling is correspondingly higher."
  default     = 10
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all created resource names (<= 19 chars). Must match what the backend persisted for this connection, or a re-fetched artifact will not line up with the deployed names."
  default     = "armo-cdr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphen, start with a letter, and be <= 19 chars (keeps derived SA ids within GCP's 30-char cap)."
  }
}

variable "heartbeat_interval" {
  type        = string
  description = "Liveness heartbeat cadence as a Go duration. The backend disconnects an organization whose keep-alive goes stale, so this must stay well below that threshold."
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

# ---- connectivity check (D2, HLD §4.4) --------------------------------------
variable "run_connectivity_check" {
  type        = bool
  description = <<-EOT
    Fire the retried D2 connectivity check after the pipe is up, so a qualifying
    Admin Activity log traverses sink → Pub/Sub → collector within ~2–4 min even
    across a completely dormant organization. Requires the gcloud CLI on PATH.
  EOT
  default     = true
}

variable "connectivity_check_attempts" {
  type        = number
  description = "Number of forced-mutation probe events to fire. The RETRY IS MANDATORY: a single T+0 check is lost to the ~2-min sink-activation window (POC-measured)."
  default     = 8
}

variable "connectivity_check_interval_seconds" {
  type        = number
  description = "Seconds between probe attempts. 8 attempts × 30s ≈ 4 min covers the measured activation window with margin."
  default     = 30
}
