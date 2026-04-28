#!/usr/bin/env bash
# Wait for the VM to be ready: docker daemon up and infra.env populated.
# Required env: VM_NAME, VM_ZONE
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env VM_NAME
need_env VM_ZONE

# `test -s` catches the empty-file race where the startup script touched
# infra.env before writing it; the grep ensures DOMAIN was actually emitted.
PREDICATE='sudo docker info >/dev/null 2>&1 \
  && test -s /opt/app/state/infra.env \
  && grep -q "^DOMAIN=" /opt/app/state/infra.env'

vm_ready() {
  gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --tunnel-through-iap --quiet \
    --command="$PREDICATE" >/dev/null 2>&1
}

log "waiting for VM $VM_NAME in $VM_ZONE to be ready"
wait_until "VM $VM_NAME" 30 10 vm_ready \
  || fail "VM never became ready. Did make all-bootstrap finish? Check 'sudo cat /var/log/startup.log' on the VM."
log "VM ready (docker up, infra.env populated)"
