#!/bin/sh
# valkey-cli logged in as admin; run inside the pod: sh /etc/valkey/cli.sh [valkey-cli args]
# the password is read from the mounted ACL file and never printed
set -eu

# admin's line looks like: user admin on >PASSWORD ~* &* +@all
VALKEYCLI_AUTH=$(awk '$1 == "user" && $2 == "admin" {
  for (i = 3; i <= NF; i++) if ($i ~ /^>/) { print substr($i, 2); exit }
}' /etc/valkey-acl/users.acl)
export VALKEYCLI_AUTH

exec valkey-cli --user admin "$@"
