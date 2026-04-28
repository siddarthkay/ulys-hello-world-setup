resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Private Services Access: reserved range that Cloud SQL + Memorystore peer
# into so they get private IPs reachable from the VPC.
resource "google_compute_global_address" "psa_range" {
  name          = "${var.name_prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]

  deletion_policy = "ABANDON"
}

# Serverless VPC Connector: how Cloud Run reaches Cloud SQL + Memorystore
# private IPs. /28 minimum. min/max instances control HA and burst capacity.
resource "google_vpc_access_connector" "connector" {
  name          = "${var.name_prefix}-vpc-conn"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.vpc_connector_cidr
  min_instances = 2
  max_instances = 3
  machine_type  = "e2-micro"
}
