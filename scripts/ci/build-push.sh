#!/usr/bin/env bash
# Build + push three images to Artifact Registry: api, worker, web.
#
# Required env:
#   IMAGE_REGISTRY  e.g. us-central1-docker.pkg.dev/PROJECT/ulys-images
#   IMAGE_TAG       short SHA
#   GIT_SHA         full SHA, baked into /version
#   BUILD_TIME      RFC3339 timestamp, baked into /version
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env GIT_SHA
need_env BUILD_TIME

REGISTRY_HOST=${IMAGE_REGISTRY%%/*}

log "configure docker auth for $REGISTRY_HOST"
gcloud auth configure-docker "$REGISTRY_HOST" --quiet

build_push() {
  local name=$1 context=$2 dockerfile=$3
  shift 3
  log "build & push $name -> $IMAGE_REGISTRY/$name:$IMAGE_TAG"
  docker buildx build "$context" \
    ${dockerfile:+--file "$dockerfile"} \
    --push \
    --tag "$IMAGE_REGISTRY/$name:$IMAGE_TAG" \
    "$@"
}

build_push api    "$ROOT/app/api" "" \
  --build-arg "GIT_SHA=$GIT_SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME"

build_push worker "$ROOT/app/worker" ""

build_push web    "$ROOT/app/web" ""
