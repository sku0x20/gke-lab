# gke-lab

## Workflow

- Commit after every meaningful change.

## Secrets in OpenTofu

- Mark secret variables/outputs `sensitive = true`. Still plaintext in state, so also:
- Prefer `ephemeral` blocks and write-only (`*_wo`) args where supported; they never reach state or plan. Rotate by bumping `*_wo_version`.
- No long-lived credentials in tofu: no `google_service_account_key`; use Workload Identity.
- Secret Manager: tofu owns the secret, not the value (`_wo` or `gcloud secrets versions add`).
