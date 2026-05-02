locals {
  common_labels = {
    app     = var.name_prefix
    managed = "terraform"
  }
}

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  zone = data.google_compute_zones.available.names[0]
}
