# Project-level roles the GHA SA needs to apply main TF + deploy via gcloud.
# These are intentionally broad for a take-home; production should split
# plan-only and apply roles, with apply gated on env approval.
locals {
  gha_project_roles = [
    # Networking + LB resources
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/compute.loadBalancerAdmin",
    # Buckets (state, web, deploy artifacts)
    "roles/storage.admin",
    # IAM + service-account management
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    # Cloud Run deploys
    "roles/run.admin",
    # Cloud SQL + Memorystore
    "roles/cloudsql.admin",
    "roles/redis.admin",
    # Service Networking (PSA peering)
    "roles/servicenetworking.networksAdmin",
    # Serverless VPC connector
    "roles/vpcaccess.admin",
    # Image registry, secrets
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    # Service usage (enable APIs etc.)
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

resource "google_project_iam_member" "gha_roles" {
  for_each = toset(local.gha_project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gha.email}"
}
