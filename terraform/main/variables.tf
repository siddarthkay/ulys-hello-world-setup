variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for regional resources (IP, Artifact Registry, GCS buckets). Zone is derived from this; see locals.tf."
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
  description = "Email of the GitHub Actions service account from the bootstrap module's output. CI impersonates k8s_deployer_sa via this identity."
}

variable "k3s_server_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for the k3s control-plane node. Needs ~4 GB RAM to host k3s + Prometheus + cert-manager + ESO + Argo Rollouts."
}

variable "k3s_agent_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for the k3s worker node. Hosts api/worker rollouts, postgres, redis, web, Caddy ingress."
}

variable "k3s_version" {
  type        = string
  default     = "v1.30.6+k3s1"
  description = "k3s release pinned in cloud-init via INSTALL_K3S_VERSION."
}

variable "pgdata_disk_gb" {
  type        = number
  default     = 10
  description = "Persistent disk size for the Postgres PV. Attached to the agent; bound by the postgres StatefulSet's PVC."

  validation {
    condition     = var.pgdata_disk_gb >= 5
    error_message = "pgdata_disk_gb must be at least 5 GB; Postgres + headroom needs more space."
  }
}
