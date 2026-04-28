# Cloud SQL Postgres — smallest viable tier, private-IP only.
# - db-f1-micro: shared-core, 0.6 GB RAM. ~$9/mo zonal. Not HA.
# - 10 GB HDD storage.
# - No public IP. Reachable from the VM via the VPC peering established in network.tf.

resource "google_sql_database_instance" "pg" {
  name             = "${var.name_prefix}-pg"
  database_version = "POSTGRES_16"
  region           = var.region

  deletion_protection = false

  settings {
    # GCP started defaulting new SQL instances to ENTERPRISE_PLUS in some
    # accounts; shared-core tiers like db-f1-micro only exist on ENTERPRISE.
    edition           = "ENTERPRISE"
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = 10
    disk_autoresize   = false

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = false
    }

    backup_configuration {
      enabled = false
    }

    insights_config {
      query_insights_enabled = false
    }
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
}

# Cloud SQL Postgres requires a password at user creation time (unlike MySQL,
# which allows password-less users). To minimize the time the password lives in
# Terraform state, we create the user with a *transient* random password here
# and `scripts/bootstrap-finish.sh` rotates it to a strong value that is
# written to Secret Manager. After rotation, the value in TF state is dead —
# it can no longer be used to authenticate. `ignore_changes = [password]`
# prevents a future `terraform apply` from reverting the rotated password.
resource "random_password" "transient_db" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
  password = random_password.transient_db.result

  deletion_policy = "ABANDON"

  lifecycle {
    ignore_changes = [password]
  }
}
