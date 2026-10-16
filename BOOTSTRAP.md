# Bootstrap

Manual GCP setup, before tofu. Run from repo root (mise env).

## Auth

```sh
gcloud auth login
gcloud auth application-default login
```

## Project

```sh
gcloud projects create "$GOOGLE_PROJECT"
```

## Billing

```sh
BA=$(gcloud billing accounts list --filter=open=true --format="value(name.basename())")
gcloud billing projects link "$GOOGLE_PROJECT" --billing-account="$BA" --format=none
```

Console: Billing → Account management

## Budget

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

Alerts only, no cap.

Console: Billing → Budgets & alerts

## APIs

```sh
gcloud services enable container.googleapis.com
```

Not managed by tofu: destroy would disable them.

Console: APIs & Services → Enabled APIs & services

## Teardown

```sh
gcloud projects delete "$GOOGLE_PROJECT"
```

Delete the budget separately.
