# =============================================================================
# "Deploy to GCP" — single-project root module (SUB-7814, HLD §4.1)
#
# THE G0 INTERFACE CONTRACT. These are exactly the parameters the ARMO backend
# injects when it generates the module for a customer (the GCP analogue of AWS's
# GenerateCADRStackLink). Values arrive via a generated terraform.tfvars — see
# terraform.tfvars.example.
# =============================================================================

variable "project_id" {
  type        = string
  description = "The GCP project to onboard. The whole pipe (sink, topic, subscription, collector) is provisioned into THIS project (account-level, FR-O6)."
}

variable "region" {
  type        = string
  description = "Region for the Cloud Run collector and Pub/Sub resources."
  default     = "us-central1"
}

variable "collector_image_ref" {
  type        = string
  description = "Fully-qualified collector image ref (e.g. us-docker.pkg.dev/elated-pottery-310110/armosec-public/cdr-gcp:gcp-v0.0.1). Tagged `gcp-v<x.y.z>` by the release pipeline — a parameter so the deploy pins an explicit version."
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

# ---- compute / idle model (defaults are the resolved HLD choices) -----------
variable "min_instances" {
  type        = number
  description = "Cloud Run min instances. 1 = always-on (OQ-GCP-6). Do not set 0 in production."
  default     = 1
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all created resource names (<= 19 chars)."
  default     = "armo-cdr"

  # Mirror the collector-stack module's rule so a bad value fails here, tied to
  # this input, instead of surfacing later from inside the module.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphen, start with a letter, and be <= 19 chars (keeps derived SA ids within GCP's 30-char cap)."
  }
}

# ---- connectivity check (D2, HLD §4.4) --------------------------------------
variable "run_connectivity_check" {
  type        = bool
  description = <<-EOT
    After the pipe is up, fire the retried D2 connectivity-check so a qualifying
    Admin Activity log traverses sink → Pub/Sub → collector within ~2–4 min even
    in a completely dormant project — bounding onboarding instead of waiting on
    organic activity. Requires the gcloud CLI on PATH (used for auth already).
    Set false to skip (e.g. CI plan-only) and run scripts/connectivity-check.sh
    separately.
  EOT
  default     = true
}

variable "connectivity_check_attempts" {
  type        = number
  description = "Number of forced-mutation probe events to fire. The RETRY IS MANDATORY: a single T+0 check is lost to the ~2-min sink-activation window (POC-measured); several attempts spread across the window guarantee one lands after it."
  default     = 8
}

variable "connectivity_check_interval_seconds" {
  type        = number
  description = "Seconds between probe attempts. 8 attempts × 30s ≈ 4 min covers the measured activation window with margin."
  default     = 30
}

variable "heartbeat_interval" {
  type        = string
  description = "Liveness heartbeat cadence as a Go duration. The backend disconnects an account whose keep-alive goes stale, so this must stay well below that threshold; the default matches Azure."
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
