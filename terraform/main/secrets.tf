# Secret containers exist outside Terraform: bootstrap creates them and
# scripts/all-bootstrap.sh writes the values via `gcloud secrets versions
# add`. Main TF references them as data sources only, so the values are
# never read into TF state.

data "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name_prefix}-db-password"
}

data "google_secret_manager_secret" "worker_secret" {
  secret_id = "${var.name_prefix}-worker-secret"
}

# ESO uses ADC = the metadata creds of whichever node it's scheduled on.
# It can land on either, so both node SAs need accessor on both secrets.
locals {
  node_sa_emails = [
    google_service_account.k3s_server.email,
    google_service_account.k3s_agent.email,
  ]
}

resource "google_secret_manager_secret_iam_member" "nodes_read_db" {
  for_each  = toset(local.node_sa_emails)
  secret_id = data.google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value}"
}

resource "google_secret_manager_secret_iam_member" "nodes_read_worker" {
  for_each  = toset(local.node_sa_emails)
  secret_id = data.google_secret_manager_secret.worker_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value}"
}
