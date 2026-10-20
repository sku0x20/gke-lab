data "google_client_config" "this" {}

# Mongo backups (PBM). Lives here so backups outlive the per-session cluster.
# PBM writes via Workload Identity (no keys); the IAM binding is in dynamic, next to the cluster
resource "google_storage_bucket" "mongo_backup" {
  name     = "${data.google_client_config.this.project}-mongo-backup" # bucket names are global
  location = "asia-south1"                                            # same region as the cluster: no egress

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # backstop only: PBM's cleanup (k8s/mongo/backup-cleanup.yaml) keeps 48h PITR / 7d backups,
  # but only runs while the cluster is up
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}
