#!/usr/bin/env bash
# Deletes one app: everything kapp deployed as app <app>.
# Usage: k8s/destroy.sh <app>
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
app=${1:?usage: $0 <app>}

if [ ! -f "$dir/$app/kustomization.yaml" ]; then
  echo "no app '$app': expected $dir/$app/kustomization.yaml" >&2
  exit 1
fi

kapp delete -a "$app"
