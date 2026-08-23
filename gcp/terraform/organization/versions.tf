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
    # Used by the connectivity-check null_resource in main.tf.
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}

# The provider is pinned to the SECURITY project: every resource this root creates
# lives there. The org/folder sinks are the exception — they are org- and
# folder-scoped resources and take their scope from their own arguments, not from
# the provider's project.
provider "google" {
  project = var.security_project
  region  = var.region
}
