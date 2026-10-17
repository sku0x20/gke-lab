# owned by infra/static; looked up by name so this root doesn't read its state.
# apply static first: these fail the plan if it isn't
data "google_compute_network" "vpc" {
  name = "lab"
}

data "google_compute_subnetwork" "gke" {
  name = "gke"
}

# static also grants its node role; that must exist before nodes boot, or logging/metrics fail
data "google_service_account" "gke_nodes" {
  account_id = "gke-nodes"
}

data "google_secret_manager_secret" "valkey_acl" {
  secret_id = "valkey-acl"
}
