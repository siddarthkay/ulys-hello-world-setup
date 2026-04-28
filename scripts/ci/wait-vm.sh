#!/usr/bin/env bash
# Wait for the VM's startup script to finish: secrets.env + infra.env present.
# Required env: VM_NAME, VM_ZONE
source "$(dirname "$0")/_lib.sh"
need_env VM_NAME
need_env VM_ZONE

log "waiting for VM $VM_NAME in $VM_ZONE to be ready"
for i in $(seq 1 30); do
  if gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --tunnel-through-iap --quiet \
       --command="test -s /opt/app/state/secrets.env && test -s /opt/app/state/infra.env" \
       >/dev/null 2>&1; then
    log "VM ready"
    exit 0
  fi
  printf '  not ready yet (%d/30) — startup script still running or secrets not populated\n' "$i"
  sleep 10
done
fail "VM never became ready. Did you run scripts/bootstrap-finish.sh after the first apply?"
