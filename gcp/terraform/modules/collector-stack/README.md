# `collector-stack` — scope-independent CDR collector core

Reusable Terraform module that provisions everything the ARMO CDR collector needs
that does **not** depend on the log-source scope:

- API enablement (`run`, `pubsub`, `logging`, `secretmanager`, `iam`)
- Pub/Sub audit **topic** + **DLQ topic** + a DLQ **subscription** (so dead-lettered
  events are recoverable, not discarded)
- The **OIDC-authenticated push subscription** with the POC-validated resilience
  config (retry policy + `max_delivery_attempts`)
- The **Cloud Run collector** (private; `min-instances=1` always-on) + its
  least-privilege **runtime SA** and the **pusher SA**
- The **access-key secret** (Secret Manager) wired into Cloud Run as a secret-backed
  env var, plus all the Pub/Sub service-agent IAM

It intentionally does **not** create the Log Router **sink**. The sink resource and
its writer-identity grant differ by scope — a project sink, an organization sink,
and a folder sink each have a *different* writer-identity shape (HLD §4.2), and
reusing the wrong shape fails **silently** (no error, no logs). The caller creates
the sink for its scope and grants `roles/pubsub.publisher` to that sink's own
`writer_identity` on `topic_name`.

## Consumers

| Root | Scope | Ticket | Sink it adds |
|------|-------|--------|--------------|
| [`../../single-project`](../../single-project) | one project | **SUB-7814** (this) | `google_logging_project_sink` |
| `../../organization` | org + folder scoping | SUB-7815 (G6, later) | `google_logging_organization_sink` / folder sinks |

## The G0 interface contract

The five backend-injected inputs (`customer_guid`, `access_key`, `alert_export_url`,
`rule_endpoint_url`, `collector_image_ref`) map to the collector container env as:

| Input | Container env | Notes |
|-------|---------------|-------|
| `customer_guid` | `ARMO_CUSTOMER_GUID` | ARMO CustomerGUID (`ARMO_`-prefixed platform value, shared w/ Azure) |
| `alert_export_url` | `ARMO_ALERT_URL` | alert POST target (FR-A1) |
| `rule_endpoint_url` | `ARMO_RULE_ENDPOINT_URL` | managed rule delivery (FR-D5) — new vs AWS |
| `access_key` | `ARMO_ACCESS_KEY` | **secret-backed**, from Secret Manager — never plaintext |
| `collector_image_ref` | container image | left as a param — image is G4/SUB-7813, not built yet |
| `project_id` | `GCP_PROJECT_ID` | onboarded scope; feeds `CloudMetadata.accountID` (SUB-7649) |
| `region` | `GCP_REGION` | — |

This mapping **is** the contract the G4 collector image must read.
