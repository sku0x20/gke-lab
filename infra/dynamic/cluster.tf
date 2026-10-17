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

resource "google_container_cluster" "lab" {
  name                = "lab"
  location            = "asia-south1" # Autopilot is regional only
  enable_autopilot    = true
  deletion_protection = false # tofu-side guard; off so tofu destroy works each session

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  # VPC-native: pods and services get IPs from the subnet's secondary ranges
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
    stack_type                    = "IPV4_IPV6" # pods get an IPv6 too: pod IPv6 from the subnet, service IPv6 picked by GKE; no secondary ranges needed
  }

  # nodes get internal IPs only; outbound goes through Cloud NAT
  private_cluster_config {
    enable_private_nodes = true
  }

  # API server reachable only via its DNS name, gated by IAM; no IP endpoint, no authorized networks
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # on Autopilot this only sets node defaults; GKE manages the autoscaling itself
  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = google_service_account.gke_nodes.email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"] # access is limited by IAM roles, not scopes
    }
  }

  # nodes must have their role before they boot, or logging/metrics fail
  depends_on = [google_project_iam_member.gke_nodes]
}
