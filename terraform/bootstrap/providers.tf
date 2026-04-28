terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Bills every API call against this project (X-Goog-User-Project header).
  # Required for APIs like billingbudgets that reject user-credential calls
  # without an explicit quota project.
  billing_project       = var.project_id
  user_project_override = true
}

# Shared labels applied to every resource that supports them.
locals {
  common_labels = {
    app     = var.name_prefix
    managed = "terraform"
  }
}
