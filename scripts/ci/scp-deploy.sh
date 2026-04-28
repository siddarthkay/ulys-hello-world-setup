#!/usr/bin/env bash
# Copy deploy/ artifacts and the static site into /opt/app/ on the VM.
# Required env: VM_NAME, VM_ZONE
source "$(dirname "$0")/_lib.sh"
need_env VM_NAME
need_env VM_ZONE

log "scp deploy/ + app/web → $VM_NAME:/tmp/deploy/"
gcloud compute scp --recurse \
  --zone="$VM_ZONE" --tunnel-through-iap --quiet \
  "$ROOT/deploy/compose.infra.yml" \
  "$ROOT/deploy/compose.app.yml" \
  "$ROOT/deploy/deploy.sh" \
  "$ROOT/deploy/caddy" \
  "$ROOT/app/web" \
  "$VM_NAME:/tmp/deploy/"

log "install into /opt/app/"
gcloud compute ssh "$VM_NAME" \
  --zone="$VM_ZONE" --tunnel-through-iap --quiet \
  --command="sudo install -d /opt/app/caddy /opt/app/web && \
             sudo cp /tmp/deploy/compose.infra.yml /opt/app/ && \
             sudo cp /tmp/deploy/compose.app.yml /opt/app/ && \
             sudo cp /tmp/deploy/deploy.sh /opt/app/ && \
             sudo cp -r /tmp/deploy/caddy/. /opt/app/caddy/ && \
             sudo cp -r /tmp/deploy/web/. /opt/app/web/ && \
             sudo chmod +x /opt/app/deploy.sh"
