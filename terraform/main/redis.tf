# Memorystore Redis — Basic tier, 1 GB minimum (~$33/mo).
# Private-only via the VPC peering range.

resource "google_redis_instance" "cache" {
  name           = "${var.name_prefix}-redis"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region

  authorized_network = google_compute_network.vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_7_2"
  display_name  = "${var.name_prefix} cache"

  # No auth/TLS for simplicity — network isolation already prevents external
  # reach. Production should enable both.
  auth_enabled            = false
  transit_encryption_mode = "DISABLED"

  depends_on = [google_service_networking_connection.psa]
}
