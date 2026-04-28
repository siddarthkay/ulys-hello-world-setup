# Memorystore Redis: STANDARD_HA tier (replica with automatic failover).
# ~$70/mo for 1 GB. Audit's A pick, traded against Basic ($33/mo) for HA.

resource "google_redis_instance" "cache" {
  name           = "${var.name_prefix}-redis"
  tier           = "STANDARD_HA"
  memory_size_gb = var.redis_memory_gb
  region         = var.region

  authorized_network = google_compute_network.vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_7_2"
  display_name  = "${var.name_prefix} cache (HA)"

  # Network isolation already blocks external reach; for prod, enable
  # auth + TLS in addition.
  auth_enabled            = false
  transit_encryption_mode = "DISABLED"

  labels = merge(local.common_labels, { component = "redis" })

  depends_on = [google_service_networking_connection.psa]
}
