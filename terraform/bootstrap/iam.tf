# Project-level roles the GHA SA needs to apply main TF + deploy.
locals {
  gha_project_roles = [
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/storage.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iap.tunnelResourceAccessor",
    "roles/compute.osAdminLogin",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
  ]
}

resource "google_project_iam_member" "gha_roles" {
  for_each = toset(local.gha_project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gha.email}"
}
