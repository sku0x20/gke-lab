# Valkey's ACL file (users and passwords), mounted into the pod by the Secret Manager add-on.
# tofu owns the secret, not the value: versions are added by k8s/valkey/add-acl-secret.sh
resource "google_secret_manager_secret" "valkey_acl" {
  secret_id = "valkey-acl"

  # Google picks the locations; billed as one location
  replication {
    auto {}
  }
}

# Mongo secrets the operator would otherwise generate per cluster. Kept here so a backup can be
# restored into a new cluster: a physical restore needs the same encryption key, and backups
# contain the system users, so their passwords must match. Synced into Kubernetes Secrets by
# GKE Secret Sync (k8s/mongo).
# Values: generated once by tofu and written write-only, never in state or plan.
# Bumping a version writes a new value; mongod is not updated by that.
locals {
  mongo_secrets = {
    # encryption-at-rest master key: base64 of 32 bytes. NEVER rotate this way: existing data
    # and every physical backup stay encrypted with the old key
    "mongo-encryption-key" = { version = 1 }
    # system users' passwords (usernames are the operator's defaults)
    "mongo-backup-password"          = { version = 1 }
    "mongo-cluster-admin-password"   = { version = 1 }
    "mongo-cluster-monitor-password" = { version = 1 }
    "mongo-user-admin-password"      = { version = 1 }
    "mongo-database-admin-password"  = { version = 1 }
  }
}

resource "google_secret_manager_secret" "mongo" {
  for_each  = local.mongo_secrets
  secret_id = each.key

  replication {
    auto {}
  }
}

# alphanumeric: 32 chars, also usable as the 32-byte key once base64-encoded
ephemeral "random_password" "mongo" {
  for_each = local.mongo_secrets
  length   = 32
  special  = false
}

resource "google_secret_manager_secret_version" "mongo" {
  for_each = local.mongo_secrets
  secret   = google_secret_manager_secret.mongo[each.key].id

  secret_data_wo = (each.key == "mongo-encryption-key"
    ? base64encode(ephemeral.random_password.mongo[each.key].result)
    : ephemeral.random_password.mongo[each.key].result
  )
  secret_data_wo_version = each.value.version
}
