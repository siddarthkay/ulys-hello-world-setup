variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for regional resources (VM IP, Artifact Registry, GCS buckets). Zone is derived from this; see locals.tf."
}

variable "name_prefix" {
  type        = string
  default     = "ulys"
  description = "Prefix for resource names. Must match the bootstrap module's name_prefix."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "gha_service_account_email" {
  type        = string
  description = "Email of the GitHub Actions service account from the bootstrap module's output."
}

variable "vm_machine_type" {
  type        = string
  default     = "e2-small"
  description = "Compute Engine machine type for the single app VM."
}

variable "pgdata_disk_gb" {
  type        = number
  default     = 10
  description = "Persistent disk size for the Postgres container's data dir."

  validation {
    condition     = var.pgdata_disk_gb >= 5
    error_message = "pgdata_disk_gb must be at least 5 GB; Postgres + headroom needs more space."
  }
}
