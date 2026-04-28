resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "Service account for the app VM"
}

# GHA SA acts as the VM SA when SSH-ing. Explicit binding (don't rely on
# project-level admin roles to imply this).
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

locals {
  # sslip.io resolves <ip>.sslip.io → <ip> via public DNS, which lets Let's
  # Encrypt issue a real cert without owning a domain. e.g. 1.2.3.4.sslip.io.
  vm_domain = "${replace(google_compute_address.vm_ip.address, ".", "-")}.sslip.io"

  startup_script = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee /var/log/startup.log) 2>&1

    if ! command -v docker >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl gnupg jq
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      ARCH=$(dpkg --print-architecture)
      CODENAME=$(. /etc/os-release && echo $VERSION_CODENAME)
      echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi

    mkdir -p /opt/app/caddy /opt/app/web /opt/app/state /opt/app/canary

    # Auth docker for Artifact Registry pulls (uses the VM's SA).
    gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet || true

    # Fetch secrets from Secret Manager. Both must already exist (created via
    # scripts/bootstrap-finish.sh after the first `terraform apply`).
    if ! [ -s /opt/app/state/secrets.env ]; then
      DB_PASS=$(gcloud secrets versions access latest --secret=${google_secret_manager_secret.db_password.secret_id} 2>/dev/null || true)
      WS=$(gcloud secrets versions access latest --secret=${google_secret_manager_secret.worker_secret.secret_id} 2>/dev/null || true)
      if [ -n "$DB_PASS" ] && [ -n "$WS" ]; then
        cat > /opt/app/state/secrets.env <<EOF
    DB_PASSWORD=$DB_PASS
    WORKER_SECRET=$WS
    EOF
        chmod 600 /opt/app/state/secrets.env
      else
        echo "secrets not yet present in Secret Manager; CI deploy will retry"
      fi
    fi

    # Persist DB host / Redis host in env for compose.
    cat > /opt/app/state/infra.env <<EOF
    DB_HOST=${google_sql_database_instance.pg.private_ip_address}
    REDIS_HOST=${google_redis_instance.cache.host}
    REDIS_PORT=${google_redis_instance.cache.port}
    REGISTRY=${var.region}-docker.pkg.dev/${var.project_id}/${var.name_prefix}-images
    DOMAIN=${local.vm_domain}
    EOF

    # Drop a placeholder index.html so Caddy has something to serve before
    # the first deploy uploads the real one.
    if [ ! -s /opt/app/web/index.html ]; then
      cat > /opt/app/web/index.html <<'EOF'
    <!doctype html><html><body><h1>provisioned, awaiting first deploy</h1></body></html>
    EOF
    fi
  EOT
}

resource "google_compute_instance" "vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.vm_machine_type
  zone         = var.zone
  tags         = ["app-vm"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
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
  }

  metadata_startup_script = local.startup_script

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
    ]
  }

  depends_on = [
    google_project_iam_member.gha_os_admin_login,
    google_project_iam_member.gha_iap_tunnel,
    google_sql_database_instance.pg,
    google_redis_instance.cache,
  ]
}
