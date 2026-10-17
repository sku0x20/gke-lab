#!/bin/sh
# valkey-cli logged in as admin; on PATH in the pod as vcli: kubectl exec -it valkey-0 -n valkey -- vcli [valkey-cli args]
# the password is read from the mounted ACL file and never printed
set -eu

# admin's line looks like: user admin on >PASSWORD ~* &* +@all
VALKEYCLI_AUTH=$(awk '$1 == "user" && $2 == "admin" {
  for (i = 3; i <= NF; i++) if ($i ~ /^>/) { print substr($i, 2); exit }
}' /etc/valkey-acl/users.acl)
export VALKEYCLI_AUTH

exec valkey-cli --user admin "$@"
