# Shared labels applied to everything that supports them. Cost reports
# and IAM analyzers both key on these. One source of truth; if a new
# component appears, add it to var.name_prefix-derived defaults rather
# than copying labels into each .tf file.
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

locals {
  zone = data.google_compute_zones.available.names[0]
}
