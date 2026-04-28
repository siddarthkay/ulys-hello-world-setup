# Artifact Registry: one Docker repo for both api and worker images.
# Cleanup policies age-out stale images so the repo doesn't accumulate cost.

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${var.name_prefix}-images"
  format        = "DOCKER"
  description   = "Container images for api + worker"

  cleanup_policies {
    id     = "keep-latest-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-older-30d"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
}

# VM service account pulls from this repo.
resource "google_artifact_registry_repository_iam_member" "vm_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.vm.email}"
}

# GHA SA pushes to it.
resource "google_artifact_registry_repository_iam_member" "gha_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.gha_service_account_email}"
}
