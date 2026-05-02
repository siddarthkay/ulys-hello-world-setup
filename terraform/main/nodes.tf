# Static IP attached to the agent (Caddy Ingress lands there).
# sslip.io continues to give us a free public hostname for ACME.
resource "google_compute_address" "ingress_ip" {
  name   = "${var.name_prefix}-ingress-ip"
  region = var.region
}

# Persistent disk for Postgres. Attached to the agent. The deploy/ manifests
# include a PV that references this disk by name; the postgres StatefulSet's
# PVC binds to that PV. Survives node rebuilds (lifecycle.ignore_changes
# on the agent's attached_disk).
resource "google_compute_disk" "pgdata" {
  name   = "${var.name_prefix}-pgdata"
  type   = "pd-balanced"
  zone   = local.zone
  size   = var.pgdata_disk_gb
  labels = merge(local.common_labels, { component = "pgdata" })

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_compute_attached_disk" "pgdata" {
  disk        = google_compute_disk.pgdata.id
  instance    = google_compute_instance.k3s_agent.id
  device_name = "pgdata"
  mode        = "READ_WRITE"
}

locals {
  vm_domain = "${replace(google_compute_address.ingress_ip.address, ".", "-")}.sslip.io"

  server_cloud_config = templatefile("${path.module}/startup/cloud-config-server.yml", {
    region             = var.region
    project_id         = var.project_id
    vm_domain          = local.vm_domain
    k3s_version        = var.k3s_version
    k3s_token          = random_password.k3s_token.result
    k8s_deployer_email = google_service_account.k8s_deployer.email
  })

  agent_cloud_config = templatefile("${path.module}/startup/cloud-config-agent.yml", {
    region              = var.region
    project_id          = var.project_id
    k3s_version         = var.k3s_version
    k3s_token           = random_password.k3s_token.result
    agent_node_password = random_password.agent_node_password.result
    server_internal_ip  = google_compute_instance.k3s_server.network_interface[0].network_ip
  })
}

resource "google_compute_instance" "k3s_server" {
  name         = "${var.name_prefix}-k3s-server"
  machine_type = var.k3s_server_machine_type
  zone         = local.zone
  tags         = ["k3s-node", "k3s-server"]
  labels       = merge(local.common_labels, { component = "k3s-server" })

  boot_disk {
    initialize_params {
      image  = "ubuntu-os-cloud/ubuntu-2204-lts"
      size   = 20
      labels = merge(local.common_labels, { component = "k3s-server-boot" })
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  service_account {
    email  = google_service_account.k3s_server.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    user-data      = local.server_cloud_config
  }

  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }

  depends_on = [
    google_project_iam_member.gha_os_admin_login,
    google_project_iam_member.gha_iap_tunnel,
  ]
}

resource "google_compute_instance" "k3s_agent" {
  name         = "${var.name_prefix}-k3s-agent"
  machine_type = var.k3s_agent_machine_type
  zone         = local.zone
  tags         = ["k3s-node", "k3s-ingress"]
  labels       = merge(local.common_labels, { component = "k3s-agent" })

  boot_disk {
    initialize_params {
      image  = "ubuntu-os-cloud/ubuntu-2204-lts"
      size   = 20
      labels = merge(local.common_labels, { component = "k3s-agent-boot" })
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.ingress_ip.address
    }
  }

  service_account {
    email  = google_service_account.k3s_agent.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    user-data      = local.agent_cloud_config
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
      attached_disk,
    ]
  }

  depends_on = [
    google_compute_instance.k3s_server,
  ]
}
