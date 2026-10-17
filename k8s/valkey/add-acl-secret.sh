#!/usr/bin/env bash
# Adds a version to the valkey-acl secret (created empty by infra/static):
# an admin user with a random password, never printed.
# Run once after the first static apply. Rerunning rotates the password;
# Valkey reads the ACL file at startup, so restart the pod after.
set -euo pipefail

password=$(openssl rand -hex 32)

# default must be listed and turned off: if the file leaves it out,
# Valkey creates it with no password and full access
printf 'user default off\nuser admin on >%s ~* &* +@all\n' "$password" \
  | gcloud secrets versions add valkey-acl --data-file=-
