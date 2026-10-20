data "google_client_config" "this" {}

# Mongo backups (PBM). Lives here so backups outlive the per-session cluster.
# PBM writes via Workload Identity (no keys); the IAM binding is in dynamic, next to the cluster
resource "google_storage_bucket" "mongo_backup" {
  name     = "${data.google_client_config.this.project}-mongo-backup" # bucket names are global
  location = "asia-south1"                                            # same region as the cluster: no egress

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # no lifecycle rules: retention is managed in k8s/mongo (backup-cleanup.yaml, backup-copy.yaml)
}
