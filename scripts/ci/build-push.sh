#!/usr/bin/env bash
# Build api + worker images and push to Artifact Registry.
# Required env:
#   IMAGE_REGISTRY  e.g. us-central1-docker.pkg.dev/PROJECT/ulys-images
#   IMAGE_TAG       short SHA tag
#   GIT_SHA         full SHA, baked into /version
#   BUILD_TIME      RFC3339 timestamp, baked into /version
source "$(dirname "$0")/_lib.sh"
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env GIT_SHA
need_env BUILD_TIME

REGISTRY_HOST=${IMAGE_REGISTRY%%/*}

log "configure docker auth for $REGISTRY_HOST"
gcloud auth configure-docker "$REGISTRY_HOST" --quiet

log "build & push api  → $IMAGE_REGISTRY/api:$IMAGE_TAG"
docker buildx build "$ROOT/app/api" \
  --push \
  --tag "$IMAGE_REGISTRY/api:$IMAGE_TAG" \
  --tag "$IMAGE_REGISTRY/api:latest" \
  --build-arg "GIT_SHA=$GIT_SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME"

log "build & push worker → $IMAGE_REGISTRY/worker:$IMAGE_TAG"
docker buildx build "$ROOT/app/worker" \
  --push \
  --tag "$IMAGE_REGISTRY/worker:$IMAGE_TAG" \
  --tag "$IMAGE_REGISTRY/worker:latest"
