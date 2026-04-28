variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "project_number" {
  type        = string
  description = "GCP project number (numeric). `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for the state bucket and any other regional bootstrap resources."
}

variable "name_prefix" {
  type        = string
  default     = "ulys"
  description = "Prefix for resource names. Must match terraform/main's name_prefix."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique GCS bucket name for Terraform state (e.g. <project>-tfstate)."
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in 'owner/name' form (e.g. siddarthkay/ulys-devops-take-home)."
}

variable "billing_account_id" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). `gcloud beta billing accounts list`"
}

variable "budget_alert_email" {
  type        = string
  description = "Email to receive budget alert notifications."
}
