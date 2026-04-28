output "project_id" {
  value       = var.project_id
  description = "GCP project ID, surfaced for tooling that needs it without re-reading tfvars."
}

output "state_bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "Name of the GCS bucket holding main TF state."
}

output "wif_provider" {
  value       = "projects/${var.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
  description = "Workload identity provider resource path."
}

output "gha_service_account_email" {
  value       = google_service_account.gha.email
  description = "Email of the GitHub Actions service account."
}
