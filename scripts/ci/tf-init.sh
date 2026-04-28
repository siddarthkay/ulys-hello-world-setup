#!/usr/bin/env bash
# Initialize terraform/main with the GCS backend.
source "$(dirname "$0")/_lib.sh"
need_env GCP_TF_STATE_BUCKET

log "terraform init (bucket=$GCP_TF_STATE_BUCKET)"
terraform -chdir="$TF_MAIN" init -input=false -reconfigure \
  -backend-config="bucket=$GCP_TF_STATE_BUCKET"
