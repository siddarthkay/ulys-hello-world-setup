#!/usr/bin/env bash
# Cloud Run canary deploy with traffic-split rollback.
#
# Stages:
#   0. deploy worker latest (no traffic split for worker; api invokes it directly).
#   1. deploy api with --no-traffic --tag=cand-<sha> + --revision-suffix=<sha>.
#      Probe the candidate via the tag URL. If anything fails, undeploy.
#   2. shift 10% traffic to the new revision. Probe public LB endpoints.
#   3. shift to 50%. Probe.
#   4. shift to 100%. Probe.
#   5. on any failure, restore traffic to the previously-active revision.
#
# Required env:
#   API_SERVICE, WORKER_SERVICE   Cloud Run service names (TF outputs)
#   IMAGE_REGISTRY, IMAGE_TAG, GIT_SHA, BUILD_TIME
#   REGION                        e.g. us-central1
#   DOMAIN                        sslip.io domain on the LB IP
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env API_SERVICE
need_env WORKER_SERVICE
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env GIT_SHA
need_env BUILD_TIME
need_env REGION
need_env DOMAIN

API_IMAGE=$IMAGE_REGISTRY/api:$IMAGE_TAG
WORKER_IMAGE=$IMAGE_REGISTRY/worker:$IMAGE_TAG

# Revision suffix lets us refer to the new revision by predictable name.
# Cloud Run requires lowercase + hex-friendly chars. The IMAGE_TAG (short
# SHA) is already 12 chars hex.
REV_SUFFIX="$IMAGE_TAG"
NEW_REV="${API_SERVICE}-${REV_SUFFIX}"
TAG="cand-${IMAGE_TAG}"

# Capture the currently-active revision so we can roll back to it.
LAST_GOOD=$(gcloud run services describe "$API_SERVICE" --region="$REGION" \
  --format='value(status.traffic[0].revisionName)' 2>/dev/null || true)
log "rollback target (current 100% traffic): ${LAST_GOOD:-<none, first deploy>}"

# Probe a URL N times against /readyz; allow a small failure budget.
probe() {
  local url=$1 n=$2 max_fail=$3 fails=0
  for _ in $(seq 1 "$n"); do
    curl -fsS --max-time 5 "${url}/readyz" >/dev/null 2>&1 || fails=$((fails + 1))
  done
  log "probe $url/readyz: $fails / $n failed (max allowed $max_fail)"
  [ "$fails" -le "$max_fail" ]
}

rollback() {
  fail "rolling back: traffic reverted, candidate revision left in place but unused"
  if [ -n "$LAST_GOOD" ]; then
    gcloud run services update-traffic "$API_SERVICE" \
      --region="$REGION" \
      --to-revisions="$LAST_GOOD=100" \
      --quiet || warn "rollback traffic flip returned non-zero"
  fi
  exit 1
}

# ---- Stage 0: worker (no canary; latest goes 100%) ------------------------
log "stage 0: deploy worker $WORKER_IMAGE"
gcloud run deploy "$WORKER_SERVICE" \
  --image="$WORKER_IMAGE" \
  --region="$REGION" \
  --quiet

# ---- Stage 1: deploy candidate api revision with --no-traffic ------------
log "stage 1: deploy api candidate revision $NEW_REV (no traffic, tag=$TAG)"
gcloud run deploy "$API_SERVICE" \
  --image="$API_IMAGE" \
  --region="$REGION" \
  --revision-suffix="$REV_SUFFIX" \
  --tag="$TAG" \
  --no-traffic \
  --update-env-vars="GIT_SHA=$GIT_SHA,BUILD_TIME=$BUILD_TIME" \
  --quiet

# Tagged URL for direct probe before any public traffic.
TAG_URL=$(gcloud run services describe "$API_SERVICE" --region="$REGION" \
  --format="value(status.traffic[?tag='${TAG}'].url)" 2>/dev/null | head -1)
if [ -z "$TAG_URL" ]; then
  # Older Cloud Run formatting fallback.
  TAG_URL=$(gcloud run services describe "$API_SERVICE" --region="$REGION" --format=json \
    | jq -r ".status.traffic[] | select(.tag==\"${TAG}\") | .url")
fi
[ -n "$TAG_URL" ] || rollback

log "candidate tag URL: $TAG_URL"
probe "$TAG_URL" 20 0 || rollback

# ---- Stage 2: 10% to new ---------------------------------------------------
if [ -n "$LAST_GOOD" ]; then
  log "stage 2: 10/90 split (LAST_GOOD=$LAST_GOOD 90, $NEW_REV 10)"
  gcloud run services update-traffic "$API_SERVICE" \
    --region="$REGION" \
    --to-revisions="$NEW_REV=10,$LAST_GOOD=90" \
    --quiet
  sleep 5
  probe "https://${DOMAIN}/api" 50 2 || rollback

  log "stage 3: 50/50 split"
  gcloud run services update-traffic "$API_SERVICE" \
    --region="$REGION" \
    --to-revisions="$NEW_REV=50,$LAST_GOOD=50" \
    --quiet
  sleep 5
  probe "https://${DOMAIN}/api" 50 2 || rollback
fi

# ---- Stage 3 (or first deploy): promote 100% to new -----------------------
log "stage 4: promote $NEW_REV to 100%"
gcloud run services update-traffic "$API_SERVICE" \
  --region="$REGION" \
  --to-revisions="$NEW_REV=100" \
  --quiet
sleep 5
probe "https://${DOMAIN}/api" 50 0 || rollback

log "promoted $NEW_REV; previous=$LAST_GOOD remains at 0% (cleaned up by AR cleanup policy)"
