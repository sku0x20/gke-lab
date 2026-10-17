# custom mode: no auto subnet per region, ranges are all ours
resource "google_compute_network" "vpc" {
  name                    = "lab"
  auto_create_subnetworks = false

  # gives the VPC a private /48 from fd20::/20 (ULA, IPv6's 10.0.0.0/8); INTERNAL subnets carve /64s from it
  enable_ula_internal_ipv6 = true
}

# primary range = node IPs; secondary ranges = pod and service IPs (VPC-native)
resource "google_compute_subnetwork" "gke" {
  name                     = "gke"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true # private nodes reach Google APIs (Artifact Registry, logging) without NAT

  # dual-stack: subnet also gets an IPv6 /64; GKE carves node, pod and service IPv6 ranges from it
  stack_type       = "IPV4_IPV6"
  ipv6_access_type = "INTERNAL" # ULA, not internet-routable, matching private nodes; immutable once set

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/17"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/22"
  }
}

# private nodes have no external IP; NAT gives them outbound internet (e.g. pulling from Docker Hub)
resource "google_compute_router" "nat" {
  name    = "lab-nat"
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "lab-nat"
  router                             = google_compute_router.nat.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
