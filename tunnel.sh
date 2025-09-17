#!/usr/bin/env bash

#set -v

pids=()

cleanup() {
  echo "Ctrl+C detected! Terminating background processes..."
  kill "${pids[@]}"
  kubectl delete pod/socks-proxy -n=dbs
  exit 0
}

trap cleanup INT TERM

kubectl run socks-proxy --image=ginuerzh/gost --namespace=dbs --command -- gost -L socks5://:2080
kubectl wait --for=condition=Ready pod/socks-proxy --timeout=120s -n=dbs

kubectl port-forward pod/socks-proxy 2080:2080 -n dbs &
pids+=($!)

#gost -L=socks5://:1080 -F=socks5://127.0.0.1:2080 &
#pids+=($!)

wait
