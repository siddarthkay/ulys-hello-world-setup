# Static site bucket. CI uploads index.html via gsutil rsync. The bucket
# is fronted by the LB's backend_bucket with Cloud CDN enabled (lb.tf), so
# users hit the CDN first and miss-fall-through to GCS.

resource "google_storage_bucket" "web" {
  name                        = "${var.project_id}-web"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"
  }

  labels = merge(local.common_labels, { component = "web" })
}

# Public read so the LB's backend_bucket can serve objects to anyone.
# The bucket is only reachable via the LB if you don't memorize the
# storage.googleapis.com URL — we don't try to enforce that.
resource "google_storage_bucket_iam_member" "web_public_read" {
  bucket = google_storage_bucket.web.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# GHA SA writes to this bucket via the upload-web step.
resource "google_storage_bucket_iam_member" "gha_writes_web" {
  bucket = google_storage_bucket.web.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.gha_service_account_email}"
}
