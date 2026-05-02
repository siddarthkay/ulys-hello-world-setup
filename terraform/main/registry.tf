resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${var.name_prefix}-images"
  format        = "DOCKER"
  description   = "Container images for api, worker, web."
  labels        = merge(local.common_labels, { component = "registry" })

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

# k3s agent's kubelet pulls app images from this repo. Only the agent
# needs reader: app workloads are pinned to the agent via nodeAffinity
# so the server never tries to pull from AR.
resource "google_artifact_registry_repository_iam_member" "agent_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.k3s_agent.email}"
}

# GHA SA pushes.
resource "google_artifact_registry_repository_iam_member" "gha_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.gha_service_account_email}"
}
