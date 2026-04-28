# One-shot bootstrap. Run this ONCE locally with your own gcloud creds, BEFORE
# main TF (and before any GitHub Actions workflow runs).
#
# It creates:
#   - the GCS bucket the main TF uses for remote state
#   - enables required GCP APIs
#   - the Workload Identity Federation pool + provider for GitHub Actions
#   - a dedicated service account for GHA, with project IAM bindings
#   - a billing budget with a $20 alert threshold
#
# After running this with `terraform init && terraform apply`, copy the outputs
# into your GitHub repo settings (as Actions secrets) and into terraform/main
# `terraform.tfvars`. See README.

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

  # Force every API call to be billed against this project (sets the
  # X-Goog-User-Project header). Required for APIs like billingbudgets that
  # reject user-credential calls without an explicit quota project. Without
  # these two lines, the provider falls back to a Google-internal default
  # project and the API rejects the call as SERVICE_DISABLED.
  billing_project       = var.project_id
  user_project_override = true
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "project_number" {
  type        = string
  description = "GCP project number (numeric). `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "name_prefix" {
  type    = string
  default = "ulys"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique GCS bucket name for Terraform state (e.g. <project>-tfstate)"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in 'owner/name' form (e.g. siddarthkay/ulys-devops-take-home)"
}

variable "billing_account_id" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). `gcloud beta billing accounts list`"
}

variable "budget_alert_email" {
  type        = string
  description = "Email to receive budget alert notifications"
}

# ------------------------------------------------------------------------------
# APIs
# ------------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "billingbudgets.googleapis.com",
    "iap.googleapis.com",
    "oslogin.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------
# Remote state bucket
# ------------------------------------------------------------------------------
resource "google_storage_bucket" "tfstate" {
  name                        = var.state_bucket_name
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  versioning { enabled = true }
  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# GitHub Actions service account + Workload Identity Federation
# ------------------------------------------------------------------------------
resource "google_service_account" "gha" {
  account_id   = "${var.name_prefix}-gha"
  display_name = "GitHub Actions deployer"
  depends_on   = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.name_prefix}-github-pool"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "${var.name_prefix}-github-provider"
  display_name                       = "GitHub OIDC"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  # Lock down: only this repo can mint tokens for this provider.
  attribute_condition = "assertion.repository == '${var.github_repo}'"
}

# Allow the GH repo's OIDC tokens to impersonate the GHA service account.
resource "google_service_account_iam_member" "gha_wif_binding" {
  service_account_id = google_service_account.gha.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.repository/${var.github_repo}"
}

# Project-level roles the GHA SA needs to apply main TF + deploy.
# Kept broad-ish for take-home simplicity; production should split read vs write.
locals {
  gha_project_roles = [
    "roles/compute.admin",
    "roles/storage.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.securityAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iap.tunnelResourceAccessor",
    "roles/compute.osAdminLogin",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/cloudsql.admin",
    "roles/redis.admin",
    "roles/secretmanager.admin",
    "roles/artifactregistry.admin",
    "roles/servicenetworking.networksAdmin",
  ]
}

resource "google_project_iam_member" "gha_roles" {
  for_each = toset(local.gha_project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gha.email}"
}

# ------------------------------------------------------------------------------
# Billing budget — $20 with alerts at 50 / 90 / 100 %
# ------------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "budget_email" {
  display_name = "${var.name_prefix} budget alert email"
  type         = "email"
  labels = {
    email_address = var.budget_alert_email
  }
  depends_on = [google_project_service.apis]
}

resource "google_billing_budget" "twenty_dollar" {
  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix}-budget"

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      # ₹1700 ≈ $20 USD — billing account is in INR, the Budget API requires
      # the budget currency to match.
      currency_code = "INR"
      units         = "1700"
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.budget_email.id,
    ]
    disable_default_iam_recipients = false
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# Outputs — copy these into terraform/main/terraform.tfvars and GitHub secrets.
# ------------------------------------------------------------------------------
output "state_bucket" {
  value = google_storage_bucket.tfstate.name
}

output "wif_provider" {
  value = "projects/${var.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "gha_service_account_email" {
  value = google_service_account.gha.email
}
