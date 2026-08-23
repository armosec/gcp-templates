# Provider + version pinning for the CDR collector stack.
#
# The `time` provider gives us `time_sleep`, which we use to absorb a POC-measured
# gotcha: a freshly-created service account is not immediately bindable in IAM
# (SetIamPolicy fails with "does not exist" for ~4s). Without a small settle the
# first `terraform apply` in a clean project intermittently fails the pusher-SA
# invoker binding. See main.tf.
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
