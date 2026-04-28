#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
export_tf_vars

log "terraform apply"
terraform -chdir="$TF_MAIN" apply -auto-approve -input=false
