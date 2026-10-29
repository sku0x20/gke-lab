# gke-lab

## Workflow

- Commit after every meaningful change.
- Scratch space is `tmp/` in this repo (gitignored): downloaded upstream sources, rendered manifests, test files. Not the system temp dir.

## Notes

- Write notes (`k8s/<app>/NOTES.md`) as a FAQ: `##` topics, `###` questions, short direct answers with the why. Commands where they belong. `k8s/mongo/NOTES.md` is the reference.
- Crisp: no URLs, no filler. Console references as menu paths.

## Secrets in OpenTofu

- Mark secret variables/outputs `sensitive = true`. Still plaintext in state, so also:
- Prefer `ephemeral` blocks and write-only (`*_wo`) args where supported; they never reach state or plan. Rotate by bumping `*_wo_version`.
- No long-lived credentials in tofu: no `google_service_account_key`; use Workload Identity.
- Secret Manager: tofu owns the secret, not the value (`_wo` or `gcloud secrets versions add`).
