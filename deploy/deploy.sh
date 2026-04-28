#!/usr/bin/env bash
# Real canary deploy on a single VM with Caddy weighted upstreams.
#
# Stages:
#   0. bring up canary (NEW color) containers, verify direct /healthz
#   1. canary 10%   — Caddy split 90/10 (active/new)
#   2. canary 50%   — Caddy split 50/50
#   3. promote 100% — Caddy points only at new color
#   4. tear down old color
# Each stage runs a load-based smoke check; any failure reverts Caddy to
# active-only and tears the canary down.
#
# Usage: deploy.sh <IMAGE_API> <IMAGE_WORKER> <GIT_SHA> <BUILD_TIME>

set -euo pipefail

IMAGE_API="${1:?image api required}"
IMAGE_WORKER="${2:?image worker required}"
GIT_SHA="${3:-unknown}"
BUILD_TIME="${4:-unknown}"

APP_DIR=/opt/app
STATE_DIR=$APP_DIR/state
CADDY_DIR=$APP_DIR/caddy
CADDYFILE=$CADDY_DIR/Caddyfile
TMPL=$CADDY_DIR/Caddyfile.tmpl

# shellcheck source=/dev/null
source "$STATE_DIR/secrets.env"
# shellcheck source=/dev/null
source "$STATE_DIR/infra.env"

ACTIVE=$(cat "$STATE_DIR/active.color" 2>/dev/null || echo "none")
if [ "$ACTIVE" = "blue" ]; then NEW=green; else NEW=blue; fi

log() { printf '\n>>> %s\n' "$*"; }
fail() { printf '\n!!! %s\n' "$*" >&2; }

render_caddyfile() {
  # Args: mode = active_only | weighted | promote
  #       weight_active weight_new (only for weighted)
  local mode=$1
  local block
  case "$mode" in
    active_only)
      block=$(printf '      to api-%s:8080' "$ACTIVE") ;;
    weighted)
      local wa=$2 wn=$3
      block=$(printf '      to api-%s:8080 api-%s:8080\n      lb_policy weighted_round_robin %s %s' \
                "$ACTIVE" "$NEW" "$wa" "$wn") ;;
    promote)
      block=$(printf '      to api-%s:8080' "$NEW") ;;
    *)
      fail "render_caddyfile: bad mode $mode"; return 1 ;;
  esac
  awk -v d="$DOMAIN" -v u="$block" '
    {
      gsub(/__DOMAIN__/, d)
      if ($0 ~ /__UPSTREAMS_BLOCK__/) print u; else print
    }
  ' "$TMPL" > "$CADDYFILE.new"
  mv "$CADDYFILE.new" "$CADDYFILE"

  # Validate first — fail fast if the rendered file is malformed.
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null

  # Full restart instead of `caddy reload`. `caddy reload` does not always
  # pick up DNS for upstream container hostnames that didn't exist when Caddy
  # was first started (e.g. api-blue was NXDOMAIN at the placeholder-config
  # stage and Caddy retains stale resolver state). A restart yields fresh
  # DNS resolution and re-evaluation of all upstreams. Cert + ACME state
  # persists in the caddy_data volume so HTTPS keeps working immediately.
  docker restart caddy >/dev/null

  # Wait for Caddy to be back on :443.
  for _ in $(seq 1 15); do
    if docker exec caddy wget -q -O- --timeout=1 http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

# Dump diagnostic state when probes fail mid-stage. Helps next time something
# goes wrong on a real deploy.
dump_diag() {
  log "=== diagnostic dump ==="
  echo "--- effective Caddyfile ---"
  docker exec caddy cat /etc/caddy/Caddyfile || true
  echo "--- caddy container networks ---"
  docker inspect caddy --format '{{json .NetworkSettings.Networks}}' || true
  echo "--- can caddy resolve & reach api-$NEW? ---"
  docker exec caddy wget -q -O- --timeout=2 "http://api-$NEW:8080/healthz" || echo "  (failed)"
  echo "--- last 30 caddy log lines ---"
  docker logs --tail 30 caddy || true
  log "=== end diagnostic dump ==="
}

# Probe load: hit /api/healthz N times via the public URL, fail if error rate
# exceeds the threshold. Hits go through Caddy → either color.
probe_public() {
  local n=$1 max_fail=$2
  local fail=0
  for _ in $(seq 1 "$n"); do
    if ! curl -fsSk --max-time 3 "https://$DOMAIN/api/healthz" >/dev/null; then
      fail=$((fail + 1))
    fi
  done
  log "probe: $fail / $n failed (max allowed $max_fail)"
  [ "$fail" -le "$max_fail" ]
}

# Direct probe of one color over the docker network.
probe_direct() {
  local color=$1 path=$2
  docker run --rm --network appnet curlimages/curl:8.10.1 \
    -fsS --max-time 5 "http://api-$color:8080$path"
}

rollback() {
  fail "rolling back; reverting Caddy to active-only and tearing down canary"
  if [ "$ACTIVE" != "none" ]; then
    render_caddyfile active_only || true
  fi
  # Export env vars compose.app.yml interpolates so `down` doesn't whine.
  COLOR=$NEW \
  IMAGE_API="${IMAGE_API:-placeholder}" \
  IMAGE_WORKER="${IMAGE_WORKER:-placeholder}" \
  DB_HOST="${DB_HOST:-x}" DB_PASSWORD="${DB_PASSWORD:-x}" \
  REDIS_HOST="${REDIS_HOST:-x}" REDIS_PORT="${REDIS_PORT:-6379}" \
  WORKER_SECRET="${WORKER_SECRET:-x}" \
  GIT_SHA="${GIT_SHA:-x}" BUILD_TIME="${BUILD_TIME:-x}" \
    docker compose -f "$APP_DIR/compose.app.yml" -p "app-$NEW" down --remove-orphans 2>/dev/null || true
  exit 1
}

trap 'rollback' ERR

cd "$APP_DIR"

log "active=$ACTIVE  deploying canary=$NEW  api=$IMAGE_API  worker=$IMAGE_WORKER"

# Auth docker for Artifact Registry on this host.
gcloud auth configure-docker "${REGISTRY%%/*}" --quiet

# Infra (Caddy) up; Caddyfile must exist before container starts.
if [ ! -s "$CADDYFILE" ]; then
  if [ "$ACTIVE" != "none" ]; then
    render_caddyfile active_only
  else
    # First deploy: temporary Caddyfile with no upstreams (the file_server
    # block is enough for HTTPS issuance to succeed).
    awk -v d="$DOMAIN" '
      {
        gsub(/__DOMAIN__/, d)
        if ($0 ~ /__UPSTREAMS_BLOCK__/) print "      to 127.0.0.1:9999"; else print
      }' "$TMPL" > "$CADDYFILE"
  fi
fi
docker compose -f compose.infra.yml up -d

# ---- Stage 0: bring up canary ----
log "stage 0: bringing up canary $NEW"
COLOR=$NEW \
IMAGE_API=$IMAGE_API IMAGE_WORKER=$IMAGE_WORKER \
DB_HOST=$DB_HOST DB_PASSWORD=$DB_PASSWORD \
REDIS_HOST=$REDIS_HOST REDIS_PORT=$REDIS_PORT \
WORKER_SECRET=$WORKER_SECRET \
GIT_SHA=$GIT_SHA BUILD_TIME=$BUILD_TIME \
  docker compose -f compose.app.yml -p "app-$NEW" up -d --pull always

log "waiting for canary api-$NEW /healthz"
ok=0
for _ in $(seq 1 30); do
  if probe_direct "$NEW" /healthz >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = "1" ] || { fail "canary $NEW never became healthy"; rollback; }

log "direct /readyz on canary $NEW"
probe_direct "$NEW" /readyz
echo

log "direct /version on canary $NEW"
probe_direct "$NEW" /version
echo

log "direct /work on canary $NEW"
probe_direct "$NEW" /work
echo

# ---- Stage 1: 90/10 split ----
if [ "$ACTIVE" != "none" ]; then
  log "stage 1: 90/10 split (active=$ACTIVE 90%, new=$NEW 10%)"
  render_caddyfile weighted 90 10
  sleep 5
  probe_public 50 2 || { fail "stage 1 probe failed"; rollback; }

  # ---- Stage 2: 50/50 split ----
  log "stage 2: 50/50 split"
  render_caddyfile weighted 50 50
  sleep 5
  probe_public 50 2 || { fail "stage 2 probe failed"; rollback; }
fi

# ---- Stage 3: promote 100 ----
log "stage 3: promote $NEW to 100%"
render_caddyfile promote
sleep 5
if ! probe_public 50 0; then
  fail "stage 3 probe failed (post-promote)"
  dump_diag
  rollback
fi

# ---- Stage 4: tear down old ----
trap - ERR
if [ "$ACTIVE" != "none" ] && [ "$ACTIVE" != "$NEW" ]; then
  log "stage 4: tearing down $ACTIVE"
  docker compose -f compose.app.yml -p "app-$ACTIVE" down --remove-orphans || true
fi

echo "$NEW" > "$STATE_DIR/active.color"
log "promoted $NEW; previous=$ACTIVE torn down"
