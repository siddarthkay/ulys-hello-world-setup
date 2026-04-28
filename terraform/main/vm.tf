resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "Service account for the app VM"
}

# GHA SA acts as the VM SA when SSH-ing. Explicit binding so we don't depend
# on project-level admin roles to imply it.
resource "google_service_account_iam_member" "gha_can_use_vm_sa" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

# OS Login + IAP SSH for the GHA SA.
resource "google_project_iam_member" "gha_os_admin_login" {
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_project_iam_member" "gha_iap_tunnel" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_compute_address" "vm_ip" {
  name   = "${var.name_prefix}-vm-ip"
  region = var.region
}

# Persistent data disk for Postgres. Decoupled from the boot disk so a VM
# rebuild keeps the database.
resource "google_compute_disk" "pgdata" {
  name   = "${var.name_prefix}-pgdata"
  type   = "pd-balanced"
  zone   = local.zone
  size   = var.pgdata_disk_gb
  labels = merge(local.common_labels, { component = "pgdata" })

  lifecycle {
    # Explicitly false: `terraform destroy` deletes this disk and the
    # data on it. Snapshot first if you care:
    #   gcloud compute disks snapshot ulys-pgdata --zone=<zone> --snapshot-names=ulys-pgdata-$(date +%s)
    # Flip to true to make destroy refuse to touch the disk.
    prevent_destroy = false
  }
}

resource "google_compute_attached_disk" "pgdata" {
  disk        = google_compute_disk.pgdata.id
  instance    = google_compute_instance.vm.id
  device_name = "pgdata"
  mode        = "READ_WRITE"
}

locals {
  # sslip.io resolves <ip>.sslip.io to <ip> via public DNS, so Let's Encrypt
  # can issue a cert without us owning a domain. e.g. 1-2-3-4.sslip.io.
  vm_domain = "${replace(google_compute_address.vm_ip.address, ".", "-")}.sslip.io"

  cloud_config = templatefile("${path.module}/startup/cloud-config.yml", {
    region              = var.region
    project_id          = var.project_id
    name_prefix         = var.name_prefix
    vm_domain           = local.vm_domain
    deploy_state_bucket = google_storage_bucket.deploy_state.name
  })
}

resource "google_compute_instance" "vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.vm_machine_type
  zone         = local.zone
  tags         = ["app-vm"]
  labels       = merge(local.common_labels, { component = "vm" })

  boot_disk {
    initialize_params {
      # Ubuntu cloud image ships with cloud-init enabled and the GCE
      # datasource active, which is what makes user-data automation work.
      image  = "ubuntu-os-cloud/ubuntu-2204-lts"
      size   = 10
      labels = merge(local.common_labels, { component = "vm-boot" })
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.vm_ip.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    # cloud-init reads `user-data` via its GCE datasource. We deliberately
    # do NOT set `startup-script` here so there is exactly one automation
    # path and one place to debug.
    user-data = local.cloud_config
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
      attached_disk,
    ]
  }

  depends_on = [
    google_project_iam_member.gha_os_admin_login,
    google_project_iam_member.gha_iap_tunnel,
  ]
}
