# Cloud SQL Postgres: REGIONAL HA, point-in-time recovery, 7-day backups.
# This is the production-grade tier. Cost is real (~$70/mo).

resource "google_sql_database_instance" "pg" {
  name             = "${var.name_prefix}-pg"
  database_version = "POSTGRES_16"
  region           = var.region

  deletion_protection = false

  settings {
    edition           = "ENTERPRISE"
    tier              = var.sql_tier
    availability_type = "REGIONAL" # synchronous standby in another zone
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    insights_config {
      query_insights_enabled = true
      query_string_length    = 1024
    }

    user_labels = merge(local.common_labels, { component = "sql" })
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
}

# Postgres requires a password at user creation time. We use a transient
# random_password and let scripts/all-bootstrap.sh rotate it to the
# Secret-Manager-stored value via `gcloud sql users set-password` after
# apply. ignore_changes prevents a future apply from reverting the rotation.
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
