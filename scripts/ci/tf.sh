#!/usr/bin/env bash
# Terraform operations dispatched by subcommand.
#
# Usage: tf.sh <fmt | init | validate | plan | apply | output>
#
#   fmt       fmt -check -recursive on terraform/
#   init      init terraform/main with the GCS backend (needs $GCP_TF_STATE_BUCKET)
#   validate  validate terraform/main
#   plan      plan terraform/main; tees output to plan.txt for PR comments
#   apply     apply terraform/main
#   output    emit non-sensitive outputs as key=value lines

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

cmd=${1:?'subcommand required: fmt | init | validate | plan | apply | output'}

case "$cmd" in
  fmt)
    log "terraform fmt -check -recursive"
    terraform -chdir="$ROOT/terraform" fmt -check -recursive
    ;;

  init)
    need_env GCP_TF_STATE_BUCKET
    log "terraform init (bucket=$GCP_TF_STATE_BUCKET)"
    terraform -chdir="$TF_MAIN" init -input=false -reconfigure \
      -backend-config="bucket=$GCP_TF_STATE_BUCKET"
    ;;

  validate)
    log "terraform validate"
    terraform -chdir="$TF_MAIN" validate
    ;;

  plan)
    export_tf_vars
    log "terraform plan"
    set -o pipefail
    terraform -chdir="$TF_MAIN" plan -no-color -input=false -out=plan.bin \
      | tee "$TF_MAIN/plan.txt"
    ;;

  apply)
    export_tf_vars
    log "terraform apply"
    terraform -chdir="$TF_MAIN" apply -auto-approve -input=false
    ;;

  output)
    terraform -chdir="$TF_MAIN" output -json | jq -r '
      to_entries
      | map(select(.value.sensitive == false))
      | .[]
      | "\(.key)=\(.value.value)"
    '
    ;;

  *)
    fail "unknown subcommand: $cmd (expected: fmt|init|validate|plan|apply|output)"
    ;;
esac
