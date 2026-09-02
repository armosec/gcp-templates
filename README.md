# ARMO GCP deployment templates

Public, versioned **Terraform modules** that ARMO's GCP CDR onboarding fetches. The dashboard's
`cadrdeploy` endpoint generates a root that pairs a `provider "google"` block with a `module {}`
block whose `source` points here, pinned to a published version tag, e.g.:

```hcl
provider "google" {
  project = "<project_id>"
  region  = "<region>"
}

module "armo_cdr" {
  source = "github.com/armosec/gcp-templates//gcp/terraform/single-project?ref=v0.1.0"
  # project_id, region, customer_guid, collector_image_ref, alert_export_url,
  # rule_endpoint_url, access_key are injected by the backend.
}
```

The `single-project` and `organization` modules are **provider-less child modules** (no
`provider "google"` block of their own): the provider is configured by the caller - the
backend-generated root above, or, for a direct run, a small root you write that pairs a
`provider "google"` block with the `module {}` call. A provider block inside a consumed module
re-triggers Terraform's "Provider configuration within modules is not recommended" warning and makes
`terraform destroy` fragile.

These are **published artifacts mirrored from the (private) `cdr-agents` repository** (`gcp/terraform`
and `gcp/scripts/connectivity-check.sh`, copied verbatim). **`cdr-agents` is the source of truth — do
not edit here by hand.** This is the GCP analogue of `armosec/azure-templates`.

**Interim host** (public GitHub); the permanent plan is a CI job in `cdr-agents` that mirrors `gcp/`
here on merge (parity with the Azure flow).

Consumers pin either a **published version tag** (`?ref=v0.1.0`) or an immutable **commit SHA**
(`?ref=<sha>`) so a deployed module always resolves to a fixed revision. Version tags are cut from
`main` after each mirrored change.

## Contents

- `gcp/terraform/single-project/` — account-level (single project) CDR collector module: Pub/Sub topic
  + DLQ + OIDC push subscription, Cloud Run collector + service accounts + least-privilege IAM, the
  project Log Router sink, and the retried D2 connectivity probe.
- `gcp/terraform/organization/` — organization-level module: aggregated whole-org sink (include_children)
  into a central security project.
- `gcp/terraform/modules/collector-stack/` — the scope-independent core both modules reuse.
- `gcp/scripts/connectivity-check.sh` — the D2 probe invoked by the modules' `local-exec` (relative
  path `../../scripts/connectivity-check.sh`), so the directory layout is preserved verbatim.

## Layout note

The `gcp/` prefix and the `terraform/` + `scripts/` structure are kept exactly as in `cdr-agents` so the
modules' relative references — `source = "../modules/collector-stack"` and
`${path.module}/../../scripts/connectivity-check.sh` — resolve unchanged when Terraform fetches a module
by its `//gcp/terraform/<scope>` subpath.
