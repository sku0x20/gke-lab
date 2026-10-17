# custom mode: no auto subnet per region, ranges are all ours
resource "google_compute_network" "vpc" {
  name                    = "lab"
  auto_create_subnetworks = false
}

# primary range = node IPs; secondary ranges = pod and service IPs (VPC-native)
resource "google_compute_subnetwork" "gke" {
  name                     = "gke"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true # private nodes reach Google APIs (Artifact Registry, logging) without NAT

  # dual-stack: subnet also gets an IPv6 /64; each node takes a /96 from it for itself and its pods
  stack_type = "IPV4_IPV6"

  # EXTERNAL = public IPv6 (no NAT66 exists): reaches IPv6-only sites, allows IPv6 L4 LBs.
  # private nodes only covers IPv4; inbound IPv6 is still blocked by the VPC's implied deny-ingress rule.
  # immutable once set
  ipv6_access_type = "EXTERNAL"

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
