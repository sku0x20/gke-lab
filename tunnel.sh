#!/usr/bin/env bash


pids=()

cleanup() {
  echo "Ctrl+C detected! Terminating background processes..."
  kill "${pids[@]}"
  exit 0
}

trap cleanup INT TERM

kubectl run socks-proxy -it --rm --restart=Never --image=ginuerzh/gost --namespace=dbs -- gost -L=socks5://:2080
kubectl port-forward pod/socks-proxy 2080:2080 -n dbs &
pids+=($!)
gost -L=socks5://:1080 -F=socks5://127.0.0.1:2080 &
pids+=($!)
wait
