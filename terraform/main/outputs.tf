output "ingress_ip" {
  value       = google_compute_address.ingress_ip.address
  description = "Public IP attached to the agent. Caddy Ingress serves 80/443 here."
}

output "domain" {
  value       = local.vm_domain
  description = "sslip.io-derived domain Caddy issues a Let's Encrypt cert for."
}

output "web_url" {
  value       = "https://${local.vm_domain}"
  description = "Browser entry point."
}

output "api_base_url" {
  value       = "https://${local.vm_domain}/api"
  description = "Caddy Ingress reverse-proxies /api/* to the api Service."
}

output "k3s_server_name" {
  value       = google_compute_instance.k3s_server.name
  description = "Name of the k3s control-plane instance; CI uses it for `gcloud compute start-iap-tunnel`."
}

output "k3s_server_zone" {
  value       = local.zone
  description = "Zone for IAP tunnel target."
}

output "k3s_agent_name" {
  value       = google_compute_instance.k3s_agent.name
  description = "Name of the k3s agent instance."
}

output "registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Fully qualified Artifact Registry repo for api, worker, web."
}

output "k8s_deployer_sa_email" {
  value       = google_service_account.k8s_deployer.email
  description = "GHA impersonates this SA to mint Google-issued OIDC ID tokens for the k8s API server."
}

output "db_password_secret_name" {
  value       = data.google_secret_manager_secret.db_password.secret_id
  description = "Secret Manager secret ID for the Postgres app-user password."
}

output "worker_secret_name" {
  value       = data.google_secret_manager_secret.worker_secret.secret_id
  description = "Secret Manager secret ID for the api->worker HMAC shared secret."
}
