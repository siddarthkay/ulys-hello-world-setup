resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true
}

# Private Services Access — reserved range that Cloud SQL + Memorystore peer into.
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

# IAP CIDR range for SSH-via-IAP. Avoids opening 22/tcp to the public internet.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["app-vm"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Public ingress on 80 (HTTP→HTTPS redirect) and 443 (HTTPS, served by Caddy).
resource "google_compute_firewall" "allow_http_https" {
  name          = "${var.name_prefix}-allow-http-https"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app-vm"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}
