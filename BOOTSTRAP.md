# Bootstrap

One-time manual setup of the GCP project, done before OpenTofu takes over.
Run everything from the repo root so the mise env (personal gcloud config, project) is active.

## 0. Auth

```sh
gcloud auth login                       # gcloud CLI
gcloud auth application-default login   # ADC, used by the tofu google provider
```

Both write into `CLOUDSDK_CONFIG` (`~/.config/gcloud-personal`), not the default `~/.config/gcloud`.

## 1. Project

```sh
gcloud projects create "$GOOGLE_PROJECT"
```

Console: [project dashboard](https://console.cloud.google.com/home/dashboard?project=lab-gke-2610)

## 2. Link billing

```sh
BA=$(gcloud billing accounts list --filter=open=true --format="value(name.basename())")
gcloud billing projects link "$GOOGLE_PROJECT" --billing-account="$BA" --format=none
gcloud billing projects describe "$GOOGLE_PROJECT" --format="value(billingEnabled)"   # True
```

`$BA` holds the billing account ID. It's never echoed, and `--format=none` keeps it out of the output.

Console: [Billing → linked account](https://console.cloud.google.com/billing/linkedaccount?project=lab-gke-2610)

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
- Spend cap enforcement exists, but only for Gemini API, Vertex AI and Cloud Run, not GKE or Compute. The real safeguards are `tofu destroy` after each session and deleting the project at the end.

Console: Billing → Budgets & alerts

## 4. APIs

```sh
gcloud services enable container.googleapis.com
```

This also enables its dependencies (`compute`, `oslogin`, ...) and creates the Compute Engine default service account.

APIs are enabled here rather than in tofu: `google_project_service` disables them on `tofu destroy` by default, and disabling `compute` while resources still exist breaks things.

Console: [enabled APIs](https://console.cloud.google.com/apis/dashboard?project=lab-gke-2610), [service accounts](https://console.cloud.google.com/iam-admin/serviceaccounts?project=lab-gke-2610)

## Teardown

```sh
gcloud projects delete "$GOOGLE_PROJECT"
```

The budget lives on the billing account, not the project, so delete it separately in Billing → Budgets & alerts.
