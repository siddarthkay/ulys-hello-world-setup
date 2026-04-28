#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
log "terraform fmt -check -recursive"
terraform -chdir="$ROOT/terraform" fmt -check -recursive
