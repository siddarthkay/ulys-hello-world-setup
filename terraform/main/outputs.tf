output "vm_external_ip" {
  value       = google_compute_address.vm_ip.address
  description = "Public IP of the VM"
}

output "vm_name" {
  value = google_compute_instance.vm.name
}

output "vm_zone" {
  value = var.zone
}

output "vm_service_account" {
  value = google_service_account.vm.email
}

output "domain" {
  value       = local.vm_domain
  description = "sslip.io-derived domain Caddy issues a Let's Encrypt cert for"
}

output "web_url" {
  value = "https://${local.vm_domain}"
}

output "api_base_url" {
  value = "https://${local.vm_domain}/api"
}

output "registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "db_instance_name" {
  value = google_sql_database_instance.pg.name
}

output "db_password_secret_name" {
  value = google_secret_manager_secret.db_password.secret_id
}

output "worker_secret_name" {
  value = google_secret_manager_secret.worker_secret.secret_id
}
