#!/usr/bin/env bash

kubectl run socks-proxy -it --rm --restart=Never --image=ginuerzh/gost --namespace=dbs -- gost -L=socks5://:2080
kubectl port-forward pod/socks-proxy 2080:2080 -n dbs
gost -L=socks5://:1080 -F=socks5://127.0.0.1:2080

