output "vm_external_ip" {
  value       = google_compute_address.vm_ip.address
  description = "Public IP of the VM."
}

output "vm_name" {
  value       = google_compute_instance.vm.name
  description = "Compute Engine instance name; consumed by SSH/IAP commands in CI."
}

output "vm_zone" {
  value       = local.zone
  description = "Zone the VM lives in (derived from region); consumed by gcloud --zone in CI."
}

output "vm_service_account" {
  value       = google_service_account.vm.email
  description = "VM SA email; reads Secret Manager + writes the deploy-state bucket."
}

output "domain" {
  value       = local.vm_domain
  description = "sslip.io-derived domain Caddy issues a Let's Encrypt cert for."
}

output "web_url" {
  value       = "https://${local.vm_domain}"
  description = "Browser entry point for the static site + reverse-proxied API."
}

output "api_base_url" {
  value       = "https://${local.vm_domain}/api"
  description = "Caddy reverse-proxies /api/* to the active color's container."
}

output "registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Fully qualified Artifact Registry repo for all four images."
}

output "deploy_state_bucket" {
  value       = google_storage_bucket.deploy_state.name
  description = "GCS bucket holding active.color (which color serves traffic)."
}

output "db_password_secret_name" {
  value       = data.google_secret_manager_secret.db_password.secret_id
  description = "Secret Manager secret ID for the Postgres app-user password."
}

output "worker_secret_name" {
  value       = data.google_secret_manager_secret.worker_secret.secret_id
  description = "Secret Manager secret ID for the api->worker HMAC shared secret."
}
