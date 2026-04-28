# Secret containers exist outside Terraform: bootstrap creates them and
# scripts/all-bootstrap.sh writes the values via `gcloud secrets versions
# add`. Main TF references them as data sources only, so the values are
# never read into TF state.
#
# IAM bindings live in cloud_run.tf (api SA needs the DB password). No
# binding for worker — it doesn't read SM.

data "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name_prefix}-db-password"
}
