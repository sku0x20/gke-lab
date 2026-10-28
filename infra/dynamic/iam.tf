data "google_project" "this" {}

locals {
  # Workload Identity principal for a Kubernetes service account, no Google SA in between.
  # the pool comes from the cluster: GKE creates it with the first cluster, so this also orders after it
  workload_pool = google_container_cluster.lab.workload_identity_config[0].workload_pool
  k8s_principal = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${local.workload_pool}/subject"
}

# Valkey's pod (KSA valkey in ns valkey) may read its ACL secret, and nothing else
resource "google_secret_manager_secret_iam_member" "valkey_acl" {
  secret_id = data.google_secret_manager_secret.valkey_acl.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.k8s_principal}/ns/valkey/sa/valkey"
}

# PBM agents (sidecar in the mongod pods, KSA mongo in ns mongo) read and write backups.
# objectUser: PBM only makes object calls (put, get, list, delete), never bucket ones
resource "google_storage_bucket_iam_member" "mongo_backup" {
  bucket = data.google_storage_bucket.mongo_backup.name
  role   = "roles/storage.objectUser"
  member = "${local.k8s_principal}/ns/mongo/sa/mongo"
}

# The operator itself checks a backup in the bucket before restoring it (metadata and file list),
# with Workload Identity as its own KSA. Read-only: PBM agents do the restore
resource "google_storage_bucket_iam_member" "mongo_backup_operator" {
  bucket = data.google_storage_bucket.mongo_backup.name
  role   = "roles/storage.objectViewer"
  member = "${local.k8s_principal}/ns/mongo/sa/percona-server-mongodb-operator"
}

# Secret Sync reads mongo's secrets as KSA mongo (SecretSync spec.serviceAccountName)
resource "google_secret_manager_secret_iam_member" "mongo" {
  for_each  = data.google_secret_manager_secret.mongo
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.k8s_principal}/ns/mongo/sa/mongo"
}
