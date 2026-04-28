variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name_prefix" {
  type        = string
  default     = "ulys"
  description = "Prefix for resource names"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in 'owner/name' form (used for WIF principal binding on the VM SA)"
}

variable "wif_provider" {
  type        = string
  description = "Full WIF provider resource name from bootstrap output (projects/N/locations/global/workloadIdentityPools/POOL/providers/PROVIDER)"
}

variable "gha_service_account_email" {
  type        = string
  description = "Email of the GitHub Actions service account from bootstrap output"
}

variable "vm_machine_type" {
  type    = string
  default = "e2-micro"
}
