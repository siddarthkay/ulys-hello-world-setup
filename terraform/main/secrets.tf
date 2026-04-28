# Secret Manager: holds the DB password and the worker shared secret.
# Crucially, NO secret values appear in this file or in TF state. We only
# create the secret containers here. Initial versions are added by
# scripts/bootstrap-finish.sh via `gcloud secrets versions add`.

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name_prefix}-db-password"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "worker_secret" {
  secret_id = "${var.name_prefix}-worker-secret"
  replication {
    auto {}
  }
}

# VM SA reads both secrets at boot.
resource "google_secret_manager_secret_iam_member" "vm_reads_db" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_secret_manager_secret_iam_member" "vm_reads_worker" {
  secret_id = google_secret_manager_secret.worker_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# GHA SA needs to create initial versions during bootstrap-finish.
resource "google_secret_manager_secret_iam_member" "gha_writes_db" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_secret_manager_secret_iam_member" "gha_writes_worker" {
  secret_id = google_secret_manager_secret.worker_secret.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${var.gha_service_account_email}"
}

output "db_password_secret_id" {
  value = google_secret_manager_secret.db_password.secret_id
}

output "worker_secret_secret_id" {
  value = google_secret_manager_secret.worker_secret.secret_id
}
