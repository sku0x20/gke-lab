# private nodes have no external IP; NAT gives them outbound internet (e.g. pulling from Docker Hub)
resource "google_compute_router" "nat" {
  name    = "lab-nat"
  network = data.google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "lab-nat"
  router                             = google_compute_router.nat.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
