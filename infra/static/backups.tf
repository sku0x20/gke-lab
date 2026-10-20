data "google_client_config" "this" {}

# Mongo backups (PBM). Lives here so backups outlive the per-session cluster.
# PBM writes via Workload Identity (no keys); the IAM binding is in dynamic, next to the cluster
resource "google_storage_bucket" "mongo_backup" {
  name     = "${data.google_client_config.this.project}-mongo-backup" # bucket names are global
  location = "asia-south1"                                            # same region as the cluster: no egress

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # default is 7 days of soft delete, billed; backups expire on purpose here
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # retention lives here, not in PBM: backup tasks keep files on delete
  # (deleteFromStorage: false), so per-session teardown can't wipe them
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}
