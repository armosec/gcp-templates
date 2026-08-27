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

# No `provider "google"` block here by design: this is consumed as a CHILD module.
# The ARMO backend wraps it in a generated root that supplies the provider; for a
# direct/manual run, wrap it in your own root that does the same (see the repo
# README). Declaring a provider inside the module re-triggers Terraform's "Provider
# configuration within modules is not recommended" warning and makes
# `terraform destroy` fragile, so the provider is configured by the CALLER instead.
