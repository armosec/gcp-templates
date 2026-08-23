# ARMO GCP deployment templates

Public, versioned **Terraform modules** that ARMO's GCP CDR onboarding fetches. The dashboard's
`cadrdeploy` endpoint generates a `module {}` block whose `source` points here, pinned to an
immutable commit SHA, e.g.:

```hcl
module "armo_cdr" {
  source = "github.com/armosec/gcp-templates//gcp/terraform/single-project?ref=<commit-sha>"
  # project_id, region, customer_guid, collector_image_ref, alert_export_url,
  # rule_endpoint_url, name_prefix, access_key are injected by the backend.
}
```

These are **published artifacts mirrored from the (private) `cdr-agents` repository** (`gcp/terraform`
and `gcp/scripts/connectivity-check.sh`, copied verbatim). **`cdr-agents` is the source of truth — do
not edit here by hand.** This is the GCP analogue of `armosec/azure-templates`.

**Interim host** (public GitHub); the permanent plan is a CI job in `cdr-agents` that mirrors `gcp/`
here on merge (parity with the Azure flow).

Consumers pin a **commit-specific** ref (`?ref=<sha>`) so a deployed module always resolves to an
immutable revision.

## Contents

- `gcp/terraform/single-project/` — account-level (single project) CDR collector module: Pub/Sub topic
  + DLQ + OIDC push subscription, Cloud Run collector + service accounts + least-privilege IAM, the
  project Log Router sink, and the retried D2 connectivity probe.
- `gcp/terraform/organization/` — organization-level module: aggregated org (or per-folder) sink into a
  central security project.
- `gcp/terraform/modules/collector-stack/` — the scope-independent core both modules reuse.
- `gcp/scripts/connectivity-check.sh` — the D2 probe invoked by the modules' `local-exec` (relative
  path `../../scripts/connectivity-check.sh`), so the directory layout is preserved verbatim.

## Layout note

The `gcp/` prefix and the `terraform/` + `scripts/` structure are kept exactly as in `cdr-agents` so the
modules' relative references — `source = "../modules/collector-stack"` and
`${path.module}/../../scripts/connectivity-check.sh` — resolve unchanged when Terraform fetches a module
by its `//gcp/terraform/<scope>` subpath.
