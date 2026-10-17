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
