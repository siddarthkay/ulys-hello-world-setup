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

# IAP CIDR for SSH (debug) on both nodes and TCP-tunneled k8s API on the server.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["k3s-node"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# k3s API server (6443) reachable only over IAP TCP tunnel from CI.
resource "google_compute_firewall" "allow_iap_k3s_api" {
  name          = "${var.name_prefix}-allow-iap-k3s-api"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["k3s-server"]
  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

# Public ingress on 80/443 to the agent (Caddy Ingress Controller).
resource "google_compute_firewall" "allow_http_https" {
  name          = "${var.name_prefix}-allow-http-https"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["k3s-ingress"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# Intra-cluster traffic between server and agent on the subnet.
# k3s needs: 6443 (API), 10250 (kubelet), 8472/udp (flannel VXLAN), 51820/udp (wireguard, if enabled).
resource "google_compute_firewall" "allow_intra_cluster" {
  name          = "${var.name_prefix}-allow-intra-cluster"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = [google_compute_subnetwork.subnet.ip_cidr_range]
  target_tags   = ["k3s-node"]
  allow {
    protocol = "tcp"
    ports    = ["6443", "10250", "2379-2380"]
  }
  allow {
    protocol = "udp"
    ports    = ["8472", "51820"]
  }
}
