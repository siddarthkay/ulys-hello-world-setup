#!/usr/bin/env bash
# SSH the VM, pull images on the host, run the deploy-tools container.
# Non-zero exit means the canary failed and the old revision keeps serving.
#
# Required env:
#   VM_NAME, VM_ZONE
#   IMAGE_REGISTRY, IMAGE_TAG
#   GIT_SHA, BUILD_TIME
#   DEPLOY_STATE_BUCKET
#   DB_PASSWORD_SECRET_NAME, WORKER_SECRET_NAME   secret IDs from TF output
#
# Image pulls happen on the host (where gcloud's docker cred helper is
# configured), so the deploy-tools container itself doesn't handle registry
# auth. `timeout 600` caps a hung deploy at 10 min instead of GitHub's
# default 6h job timeout.
#
# Pulls are wrapped in a retry loop: on a freshly-applied VM, `roles/
# artifactregistry.reader` on the VM SA can take up to a couple of minutes
# to propagate through Google's IAM backends. During that window, Artifact
# Registry rejects pulls as "Unauthenticated request" even though the cred
# helper returns a valid OAuth token. Retrying a few times with backoff
# bridges the propagation gap without needing a separate readiness probe.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env VM_NAME
need_env VM_ZONE
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env GIT_SHA
need_env BUILD_TIME
need_env DEPLOY_STATE_BUCKET
need_env DB_PASSWORD_SECRET_NAME
need_env WORKER_SECRET_NAME

TIMEOUT=600

log "running deploy-tools container on $VM_NAME (tag $IMAGE_TAG)"
gcloud compute ssh "$VM_NAME" \
  --zone="$VM_ZONE" --tunnel-through-iap --quiet \
  --command="set -e
    pull() {
      local img=\$1
      for i in 1 2 3 4 5 6; do
        if sudo docker pull \"\$img\"; then return 0; fi
        echo \"pull failed (attempt \$i/6), retrying in 15s (likely IAM propagation lag)\"
        sleep 15
      done
      echo \"pull never succeeded after 6 tries: \$img\" >&2
      return 1
    }
    pull '${IMAGE_REGISTRY}/deploy-tools:${IMAGE_TAG}'
    pull '${IMAGE_REGISTRY}/api:${IMAGE_TAG}'
    pull '${IMAGE_REGISTRY}/worker:${IMAGE_TAG}'
    pull '${IMAGE_REGISTRY}/caddy-app:${IMAGE_TAG}'
    sudo timeout ${TIMEOUT} docker run --rm \\
      --network host \\
      -v /var/run/docker.sock:/var/run/docker.sock \\
      -v /opt/app/state:/state \\
      -v /opt/app/caddy:/caddy-conf \\
      -e IMAGE_API='${IMAGE_REGISTRY}/api:${IMAGE_TAG}' \\
      -e IMAGE_WORKER='${IMAGE_REGISTRY}/worker:${IMAGE_TAG}' \\
      -e IMAGE_CADDY_APP='${IMAGE_REGISTRY}/caddy-app:${IMAGE_TAG}' \\
      -e GIT_SHA='${GIT_SHA}' \\
      -e BUILD_TIME='${BUILD_TIME}' \\
      -e DEPLOY_STATE_BUCKET='${DEPLOY_STATE_BUCKET}' \\
      -e DB_PASSWORD_SECRET_NAME='${DB_PASSWORD_SECRET_NAME}' \\
      -e WORKER_SECRET_NAME='${WORKER_SECRET_NAME}' \\
      '${IMAGE_REGISTRY}/deploy-tools:${IMAGE_TAG}'"
