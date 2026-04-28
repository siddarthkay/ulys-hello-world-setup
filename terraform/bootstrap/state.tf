resource "google_storage_bucket" "tfstate" {
  name                        = var.state_bucket_name
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  labels                      = merge(local.common_labels, { component = "tfstate" })

  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }

  depends_on = [google_project_service.apis]
}
