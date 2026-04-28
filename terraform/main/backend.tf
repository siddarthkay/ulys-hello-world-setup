# Remote state in GCS. Bucket name comes from -backend-config at `terraform init` time
# (see README "Run main Terraform" section). We deliberately do not hardcode the bucket
# here so the same code works for any GCP project.
terraform {
  backend "gcs" {
    prefix = "main"
  }
}
