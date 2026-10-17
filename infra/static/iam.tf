# dedicated node identity; the default compute SA has Editor on the whole project
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes"
}

# least privilege for nodes: write logs and metrics, nothing else
resource "google_project_iam_member" "gke_nodes" {
  project = google_service_account.gke_nodes.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}
