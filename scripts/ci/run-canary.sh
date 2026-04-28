#!/usr/bin/env bash
# SSH to the VM and run deploy.sh with the new image tags.
# Non-zero exit = canary failed = workflow should fail = old revision keeps serving.
#
# Required env: VM_NAME, VM_ZONE, IMAGE_REGISTRY, IMAGE_TAG, GIT_SHA, BUILD_TIME
source "$(dirname "$0")/_lib.sh"
need_env VM_NAME
need_env VM_ZONE
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env GIT_SHA
need_env BUILD_TIME

log "running deploy.sh on $VM_NAME (canary $IMAGE_TAG)"
gcloud compute ssh "$VM_NAME" \
  --zone="$VM_ZONE" --tunnel-through-iap --quiet \
  --command="sudo bash /opt/app/deploy.sh \
    '$IMAGE_REGISTRY/api:$IMAGE_TAG' \
    '$IMAGE_REGISTRY/worker:$IMAGE_TAG' \
    '$GIT_SHA' \
    '$BUILD_TIME'"
