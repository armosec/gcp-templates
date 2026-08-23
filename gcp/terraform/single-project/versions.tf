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
    # Used by the connectivity-check null_resource in main.tf. Declared explicitly
    # so `terraform init` resolves it on a clean environment.
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
