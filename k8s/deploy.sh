#!/usr/bin/env bash
# Deploys one app: renders k8s/<app> with kustomize and applies it as kapp app <app>.
# Usage: k8s/deploy.sh <app>
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
app=${1:?usage: $0 <app>}

if [ ! -f "$dir/$app/kustomization.yaml" ]; then
  echo "no app '$app': expected $dir/$app/kustomization.yaml" >&2
  exit 1
fi

# render first: if kustomize fails, stop here. kapp given empty input
# would treat it as "app has no resources" and delete everything
manifests=$(kubectl kustomize "$dir/$app")

kapp deploy -a "$app" -f <(printf '%s\n' "$manifests")
