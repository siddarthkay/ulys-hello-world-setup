#!/usr/bin/env bash
# Build + push four images to Artifact Registry: api, worker, caddy-app,
# deploy-tools.
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
  # SHA-tagged only. We deliberately don't push :latest from build because
  # a failed canary that rolls back would leave :latest pointing at a broken
  # image. SHA-tagged images are the only safe ref; if a `latest` alias
  # is ever needed, set it from the deploy step on success.
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

# caddy-app's build context is `app/` so its Dockerfile can COPY web/ from
# the sibling directory.
build_push caddy-app "$ROOT/app" "$ROOT/app/caddy-app/Dockerfile"

build_push deploy-tools "$ROOT/app/deploy-tools" ""
