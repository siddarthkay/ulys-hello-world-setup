variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for all regional resources (Cloud Run, Cloud SQL, Memorystore, VPC connector, LB IP)."
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

variable "sql_tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Cloud SQL machine tier. db-custom-1-3840 = 1 vCPU, 3.75 GB RAM, smallest non-shared tier supporting REGIONAL HA."
}

variable "redis_memory_gb" {
  type        = number
  default     = 1
  description = "Memorystore Redis memory size in GB."
}

variable "vpc_connector_cidr" {
  type        = string
  default     = "10.20.0.0/28"
  description = "Reserved /28 inside the VPC for the Serverless VPC Connector. Must not overlap the subnet or PSA range."
}
