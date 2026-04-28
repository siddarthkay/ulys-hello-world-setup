output "domain" {
  value       = local.domain
  description = "sslip.io-derived domain on the LB IP. Cert is provisioned for this name."
}

output "web_url" {
  value       = "https://${local.domain}"
  description = "Public entry point. Resolves to the LB IP; LB serves the static site at / and the api at /api/*."
}

output "api_base_url" {
  value       = "https://${local.domain}/api"
  description = "Public API base, reverse-proxied by the LB to Cloud Run."
}

output "lb_ip" {
  value       = google_compute_global_address.lb.address
  description = "Load Balancer global IP. The managed cert is provisioned for the sslip.io-derived domain on this IP."
}

output "api_service_name" {
  value       = google_cloud_run_v2_service.api.name
  description = "Cloud Run api service name. Used by CI's deploy script."
}

output "worker_service_name" {
  value       = google_cloud_run_v2_service.worker.name
  description = "Cloud Run worker service name. Used by CI's deploy script."
}

output "api_service_account" {
  value       = google_service_account.api.email
  description = "Cloud Run api SA email."
}

output "worker_service_account" {
  value       = google_service_account.worker.email
  description = "Cloud Run worker SA email."
}

output "registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Fully qualified Artifact Registry repo for the api and worker images."
}

output "web_bucket" {
  value       = google_storage_bucket.web.name
  description = "Static-site GCS bucket. CI uploads index.html here via gsutil rsync."
}

output "db_password_secret_name" {
  value       = data.google_secret_manager_secret.db_password.secret_id
  description = "Secret Manager secret ID for the Postgres app-user password."
}

output "db_instance_name" {
  value       = google_sql_database_instance.pg.name
  description = "Cloud SQL instance name. Used by all-bootstrap.sh for the password rotation step."
}

output "vpc_connector" {
  value       = google_vpc_access_connector.connector.name
  description = "Serverless VPC Connector name."
}
