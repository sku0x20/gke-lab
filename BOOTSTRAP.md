# Bootstrap

One-time manual setup of the GCP project, done before OpenTofu takes over.
Run everything from the repo root so the mise env (personal gcloud config, project) is active.

## 0. Auth

```sh
gcloud auth login                       # gcloud CLI
gcloud auth application-default login   # ADC, used by the tofu google provider
```

Both write into `CLOUDSDK_CONFIG` (`~/.config/gcloud-personal`), not the default `~/.config/gcloud`.

```sh
gke-gcloud-auth-plugin --version
```

kubectl calls this plugin to turn your gcloud login into a token for the cluster. Without it, `get-credentials` still succeeds, but every kubectl call fails. It ships inside Homebrew's gcloud SDK, but brew links only `gcloud`, so `mise.toml` adds the SDK `bin` dir to PATH. If it's missing: `gcloud components install gke-gcloud-auth-plugin`.

## 1. Project

```sh
gcloud projects create "$GOOGLE_PROJECT"
```

Console: Home → Dashboard

## 2. Link billing

```sh
BA=$(gcloud billing accounts list --filter=open=true --format="value(name.basename())")
gcloud billing projects link "$GOOGLE_PROJECT" --billing-account="$BA" --format=none
gcloud billing projects describe "$GOOGLE_PROJECT" --format="value(billingEnabled)"   # True
```

`$BA` holds the billing account ID. It's never echoed, and `--format=none` keeps it out of the output.

Console: Billing → Account management

## 3. Budget alert

```sh
gcloud services enable billingbudgets.googleapis.com

gcloud billing budgets create \
  --billing-account="$BA" \
  --display-name="lab-gke-2610" \
  --budget-amount=8000INR \
  --filter-projects="projects/$GOOGLE_PROJECT" \
  --threshold-rule=percent=0.25 \
  --threshold-rule=percent=0.50 \
  --threshold-rule=percent=0.75 \
  --threshold-rule=percent=0.90 \
  --threshold-rule=percent=1.00 \
  --threshold-rule=percent=1.00,basis=forecasted-spend \
  --format="value(displayName)"
```

- The budget **only sends alerts** (by email to the billing admins). It does not stop spending.
- Spend cap enforcement exists, but only for Gemini API, Vertex AI and Cloud Run, not GKE or Compute. The real safeguards are destroying `infra/dynamic` after each session and deleting the project at the end.

Console: Billing → Budgets & alerts

## 4. APIs

```sh
gcloud services enable container.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
gcloud services enable secretmanager.googleapis.com
```

`container` also enables its dependencies (`compute`, `oslogin`, ...) and creates the Compute Engine default service account. `cloudresourcemanager` lets tofu read and write project IAM policy (`google_project_iam_member`). `secretmanager` holds app secrets, mounted into pods by GKE's Secret Manager add-on.

APIs are enabled here rather than in tofu: `google_project_service` disables them on `tofu destroy` by default, and disabling `compute` while resources still exist breaks things.

Console: APIs & Services → Enabled APIs & services; IAM & Admin → Service accounts

## 5. State bucket

```sh
gcloud storage buckets create "gs://$GOOGLE_PROJECT-tfstate" \
  --location=asia-south1 \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets update "gs://$GOOGLE_PROJECT-tfstate" --versioning

cat > /tmp/tfstate-lifecycle.json <<'EOF'
{
  "rule": [
    {
      "action": { "type": "Delete" },
      "condition": { "isLive": false, "numNewerVersions": 10 }
    }
  ]
}
EOF
gcloud storage buckets update "gs://$GOOGLE_PROJECT-tfstate" --lifecycle-file=/tmp/tfstate-lifecycle.json
```

- Holds the OpenTofu state. It's created by hand because tofu can't store its state in a bucket that tofu itself creates.
- Bucket names are global across all of GCS, so the project ID prefix keeps it unique.
- Public access prevention is on because state files can contain secrets.
- Versioning keeps the old copy each time the state is overwritten, so a bad apply can be rolled back. The lifecycle rule keeps the 10 most recent old versions. Count beats age here: after a long break, an age rule would leave nothing to roll back to.

Console: Cloud Storage → Buckets → Configuration / Protection / Lifecycle tabs

## 6. OpenTofu roots

Two roots, split by lifetime, each with its own state prefix in the bucket:

- `infra/static`: VPC, subnet, node service account. Free when idle; applied once and left up.
- `infra/dynamic`: Cloud NAT and the cluster. Costs while up; applied and destroyed each session.

```sh
tofu -chdir=infra/static init && tofu -chdir=infra/static apply     # once
tofu -chdir=infra/dynamic init && tofu -chdir=infra/dynamic apply   # each session
tofu -chdir=infra/dynamic destroy                                   # end of each session
```

Dynamic finds static's resources by name (data sources), so its plan fails if static isn't applied.

Static creates secrets empty; tofu never sees their values. Each app's folder under `k8s/` has a script that adds its value; run it once after the first static apply.

Don't destroy `infra/static` in the normal flow. It holds what must outlive the cluster, such as secrets, whose values would have to be re-added. To start from scratch, destroy dynamic first, then static: the VPC can't be deleted while the NAT or cluster still uses it.

## Teardown

```sh
gcloud projects delete "$GOOGLE_PROJECT"
```

The budget lives on the billing account, not the project, so delete it separately in Billing → Budgets & alerts.
