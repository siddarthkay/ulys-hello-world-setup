#!/usr/bin/env bash
# Plan main TF and write the human-readable plan to terraform/main/plan.txt
# so a workflow can attach it as a PR comment.
source "$(dirname "$0")/_lib.sh"
export_tf_vars

log "terraform plan"
set -o pipefail
terraform -chdir="$TF_MAIN" plan -no-color -input=false -out=plan.bin \
  | tee "$TF_MAIN/plan.txt"
