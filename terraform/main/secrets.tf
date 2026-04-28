# Secret containers exist outside Terraform: bootstrap creates them and
# scripts/all-bootstrap.sh writes the values via `gcloud secrets versions
# add`. Main TF references them as data sources only, so the values are
# never read into TF state. (If a future workflow sources values from
# elsewhere, e.g. KMS or Vault, this comment will need updating.)

data "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name_prefix}-db-password"
}

data "google_secret_manager_secret" "worker_secret" {
  secret_id = "${var.name_prefix}-worker-secret"
}

# VM SA reads both secrets at boot.
resource "google_secret_manager_secret_iam_member" "vm_reads_db" {
  secret_id = data.google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_secret_manager_secret_iam_member" "vm_reads_worker" {
  secret_id = data.google_secret_manager_secret.worker_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
