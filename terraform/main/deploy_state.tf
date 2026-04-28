# Tiny bucket for runtime deploy state (currently one object, active.color).
# Separate from the TF state bucket: different concerns, different IAM
# scopes, different lifecycle. Survives VM replacement.

resource "google_storage_bucket" "deploy_state" {
  name                        = "${var.project_id}-deploy-state"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  labels                      = merge(local.common_labels, { component = "deploy-state" })
}

# VM SA reads + writes active.color via the metadata-server-issued token
# from inside the deploy-tools container. Scoped to this bucket only.
resource "google_storage_bucket_iam_member" "vm_deploy_state" {
  bucket = google_storage_bucket.deploy_state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.vm.email}"
}
