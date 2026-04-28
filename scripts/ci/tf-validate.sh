#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
log "terraform validate"
terraform -chdir="$TF_MAIN" validate
