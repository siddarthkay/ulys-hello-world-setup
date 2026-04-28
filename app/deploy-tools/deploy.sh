#!/usr/bin/env bash
# Canary deploy on a single VM via Caddy weighted upstreams.
# Runs inside the deploy-tools container; talks to the host docker daemon.
#
# Stages:
#   0. bring up canary, run direct probes
#   1. caddy split 90/10 (active/new)
#   2. caddy split 50/50
#   3. promote 100% to new color
#   4. tear down old color
# Any failure rolls back: caddy points at active only, canary torn down.
#
# Required env (via `docker run -e`):
#   IMAGE_API, IMAGE_WORKER, IMAGE_CADDY_APP    image refs
#   GIT_SHA, BUILD_TIME                         baked into /version
#   DEPLOY_STATE_BUCKET                         GCS bucket holding active.color
#   DB_PASSWORD_SECRET_NAME, WORKER_SECRET_NAME Secret Manager secret IDs
#
# Required bind mounts:
#   /var/run/docker.sock   host docker daemon
#   /state                 host /opt/app/state (infra.env, deploy.lock)
#   /caddy-conf            host /opt/app/caddy (rendered Caddyfile)

set -euo pipefail

: "${IMAGE_API:?required}"
: "${IMAGE_WORKER:?required}"
: "${IMAGE_CADDY_APP:?required}"
: "${GIT_SHA:=unknown}"
: "${BUILD_TIME:=unknown}"
: "${DEPLOY_STATE_BUCKET:?required}"
: "${DB_PASSWORD_SECRET_NAME:?required}"
: "${WORKER_SECRET_NAME:?required}"

APP_DIR=/opt/deploy
STATE_DIR=/state
CADDY_CONF_DIR=/caddy-conf
CADDYFILE=$CADDY_CONF_DIR/Caddyfile
TMPL=$APP_DIR/caddy/Caddyfile.tmpl
LOCK=$STATE_DIR/deploy.lock

# infra.env (REGISTRY, DOMAIN, DEPLOY_STATE_BUCKET) is static, written
# once by the VM startup script. Postgres and Redis are containers on the
# appnet bridge, addressed by hostname (postgres:5432, redis:6379), so
# there's no host-IP indirection here.
# shellcheck source=/dev/null
. "$STATE_DIR/infra.env"

log()  { printf '\n>>> %s\n' "$*"; }
warn() { printf '\n--- %s\n' "$*"; }
fail() { printf '\n!!! %s\n' "$*" >&2; }

# Poll a predicate up to N times with a fixed sleep between attempts.
# Usage: wait_until <description> <max_attempts> <sleep_seconds> <command...>
wait_until() {
  local desc=$1 max=$2 every=$3
  shift 3
  local i
  for i in $(seq 1 "$max"); do
    if "$@"; then return 0; fi
    printf '  %s: not ready (%d/%d)\n' "$desc" "$i" "$max"
    sleep "$every"
  done
  return 1
}

# ---- metadata server helpers ----------------------------------------------
metadata_token() {
  curl -sfS -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
    | jq -r .access_token
}

metadata_project() {
  curl -sfS -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/project/project-id'
}

# ---- secrets: fetch from SM every deploy (handles rotation) ---------------
sm_read() {
  local secret=$1 token project
  token=$(metadata_token)     || { fail "metadata token fetch failed";   return 1; }
  project=$(metadata_project) || { fail "metadata project fetch failed"; return 1; }
  curl -sfS -H "Authorization: Bearer $token" \
    "https://secretmanager.googleapis.com/v1/projects/${project}/secrets/${secret}/versions/latest:access" \
    | jq -r .payload.data | base64 -d
}

log "fetching latest secrets from Secret Manager"
DB_PASSWORD=$(sm_read "$DB_PASSWORD_SECRET_NAME") || { fail "could not read $DB_PASSWORD_SECRET_NAME"; exit 1; }
WORKER_SECRET=$(sm_read "$WORKER_SECRET_NAME")    || { fail "could not read $WORKER_SECRET_NAME";    exit 1; }
[ -n "$DB_PASSWORD" ]   || { fail "DB password from SM was empty";   exit 1; }
[ -n "$WORKER_SECRET" ] || { fail "Worker secret from SM was empty"; exit 1; }
export DB_PASSWORD WORKER_SECRET

# ---- deploy lock ----------------------------------------------------------
# flock on a host-shared inode so two concurrent deploys can't race.
# Auto-allocate the fd (bash 4.1+) instead of hardcoding fd 200.
exec {LOCK_FD}>"$LOCK"
if ! flock -n "$LOCK_FD"; then
  fail "another deploy is in progress (lock at /opt/app/state/deploy.lock); refusing"
  exit 2
fi

# ---- active.color in GCS (survives VM replacement) ------------------------
# Returns "blue", "green", or "none". Any non-200 from GCS that isn't a
# clear "object missing" (404) is fatal: we don't want to silently treat a
# transient 5xx as "fresh deploy" and bring up the wrong color.
gcs_read_active() {
  local tok status body
  tok=$(metadata_token) || return 1
  body=$(mktemp)
  trap 'rm -f "$body"' RETURN
  status=$(curl -sS -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $tok" \
    "https://storage.googleapis.com/storage/v1/b/${DEPLOY_STATE_BUCKET}/o/active.color?alt=media")
  case "$status" in
    200) cat "$body" ;;
    404) echo none ;;
    *)   fail "active.color read failed: HTTP $status"; cat "$body" >&2; return 1 ;;
  esac
}

gcs_write_active() {
  local color=$1 tok
  tok=$(metadata_token) || return 1
  curl -sfS -X POST -o /dev/null \
    -H "Authorization: Bearer $tok" \
    -H "Content-Type: text/plain" \
    --data-raw "$color" \
    "https://storage.googleapis.com/upload/storage/v1/b/${DEPLOY_STATE_BUCKET}/o?uploadType=media&name=active.color"
}

ACTIVE=$(gcs_read_active)
[ "$ACTIVE" = "blue" ] && NEW=green || NEW=blue

# active.color lives in GCS and survives VM replacement. After a `terraform
# taint` rebuilds the VM, GCS may still claim blue (or green) is active
# even though the containers from that color are gone. If we trust the
# stale value, stages 1+2 will render weighted upstreams pointing at a
# non-existent api-<color> and every public probe gets a DNS lookup
# failure (502). Detect the staleness and fall back to first-deploy
# semantics: skip weighted stages, promote $NEW directly.
if [ "$ACTIVE" != "none" ] && ! docker inspect "api-$ACTIVE" >/dev/null 2>&1; then
  warn "active.color says '$ACTIVE' but api-$ACTIVE container is not on this host; treating as a fresh deploy"
  ACTIVE=none
fi

# ---- Caddyfile rendering --------------------------------------------------
# Two-step so we can write the file before caddy exists (fresh VM, first
# deploy after a `terraform taint`) without trying to docker-exec into a
# container that doesn't exist yet:
#
#   write_caddyfile_only  : awk-only, safe to call before compose-up
#   reload_caddy          : docker validate + restart + admin API ping
#   render_caddyfile      : both, used during canary stages when caddy is up

write_caddyfile_only() {
  local mode=$1 active_w=${2:-} new_w=${3:-} block
  case "$mode" in
    bootstrap)   block='      to 127.0.0.1:9999' ;;
    active_only) block=$(printf '      to api-%s:8080' "$ACTIVE") ;;
    weighted)    block=$(printf '      to api-%s:8080 api-%s:8080\n      lb_policy weighted_round_robin %s %s' "$ACTIVE" "$NEW" "$active_w" "$new_w") ;;
    promote)     block=$(printf '      to api-%s:8080' "$NEW") ;;
    *) fail "write_caddyfile_only: bad mode $mode"; return 1 ;;
  esac
  awk -v d="$DOMAIN" -v u="$block" '
    {
      gsub(/__DOMAIN__/, d)
      if ($0 ~ /__UPSTREAMS_BLOCK__/) print u; else print
    }
  ' "$TMPL" > "$CADDYFILE.new"
  mv "$CADDYFILE.new" "$CADDYFILE"
}

reload_caddy() {
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null
  # Restart, not reload: reload doesn't re-resolve DNS for upstream container
  # hostnames that didn't exist when caddy first started.
  docker restart caddy >/dev/null

  wait_until "caddy admin api" 15 1 \
    docker exec caddy wget -q -O- --timeout=1 http://127.0.0.1:2019/config/
}

render_caddyfile() {
  write_caddyfile_only "$@"
  reload_caddy
}

# ---- probes ---------------------------------------------------------------
# Public-traffic probe. Pass the path so we can exercise /readyz (which
# verifies the DB+Redis+worker chain) instead of /healthz (which only
# proves the python process is alive). Stage 1+2+3 default to /readyz.
probe_public() {
  local n=$1 max_fail=$2 path=${3:-/healthz} fails=0
  for _ in $(seq 1 "$n"); do
    curl -fsS --max-time 3 "https://${DOMAIN}/api${path}" >/dev/null 2>&1 || fails=$((fails + 1))
  done
  log "probe ${path}: $fails / $n failed (max allowed $max_fail)"
  [ "$fails" -le "$max_fail" ]
}

# Direct in-network probe: docker exec into the api container and use its
# own curl. Avoids re-pulling curlimages/curl on every call (saves a Docker
# Hub round-trip per probe).
probe_direct() {
  local color=$1 path=$2
  docker exec "api-${color}" curl -fsS --max-time 5 "http://localhost:8080${path}"
}

# Predicate variant: silent, returns just the exit status. Used by
# wait_until without bash -c indirection.
api_color_healthy() {
  docker exec "api-$1" curl -fsS --max-time 5 \
    "http://localhost:8080/healthz" >/dev/null 2>&1
}

# Wait for caddy to settle on a new upstream config: keep probing /readyz
# (same exercise the next stage's probe uses) until we see two consecutive
# successes, or give up after ~20s. Replaces the old fixed `sleep 5` which
# assumed Caddy was stable in that window.
caddy_settle() {
  local hits=0 i
  for i in $(seq 1 20); do
    if curl -fsS --max-time 2 "https://${DOMAIN}/api/readyz" >/dev/null 2>&1; then
      hits=$((hits + 1))
      [ "$hits" -ge 2 ] && return 0
    else
      hits=0
    fi
    sleep 1
  done
  warn "caddy did not settle within 20s (proceeding anyway)"
}

dump_diag() {
  log "=== diagnostic dump ==="
  echo "--- effective Caddyfile ---"
  docker exec caddy cat /etc/caddy/Caddyfile || true
  echo "--- caddy networks ---"
  docker inspect caddy --format '{{json .NetworkSettings.Networks}}' || true
  echo "--- caddy reaching api-${NEW} ---"
  docker exec caddy wget -q -O- --timeout=2 "http://api-${NEW}:8080/healthz" || echo "  (failed)"
  echo "--- last 30 caddy log lines ---"
  docker logs --tail 30 caddy || true
  log "=== end diagnostic dump ==="
}

# ---- rollback -------------------------------------------------------------
rollback() {
  fail "rolling back: caddy reverts to active-only, canary torn down"
  if [ "$ACTIVE" != "none" ]; then
    # If caddy is already running, do a full re-render + reload. Otherwise
    # (e.g. infra-up itself failed) just rewrite the file; caddy will pick
    # it up on its next start.
    if docker inspect caddy >/dev/null 2>&1; then
      render_caddyfile active_only || true
    else
      write_caddyfile_only active_only || true
    fi
  fi
  # compose.app.yml provides :-x defaults so down works without env.
  COLOR=$NEW docker compose -f "$APP_DIR/compose.app.yml" -p "app-$NEW" \
    down --remove-orphans 2>/dev/null || true
  exit 1
}

# ---- main -----------------------------------------------------------------
log "active=$ACTIVE  deploying canary=$NEW"
log "images: api=$IMAGE_API  worker=$IMAGE_WORKER  caddy-app=$IMAGE_CADDY_APP"

# Host pre-pulls all images (see scripts/ci/run-canary.sh). We just verify
# they're cached so we fail fast with a clear message if not.
log "verifying images are pre-cached on the host"
for img in "$IMAGE_API" "$IMAGE_WORKER" "$IMAGE_CADDY_APP"; do
  docker image inspect "$img" >/dev/null 2>&1 || {
    fail "image not pre-cached on host: $img. Run 'docker pull $img' on the VM first, or use 'make deploy'."
    exit 1
  }
done

# Always rewrite the Caddyfile to a known-good state before compose-up,
# even if a file from a previous (possibly-failed) run is on disk. The
# previous file may point at a container that no longer exists. We use
# write_caddyfile_only here, NOT render_caddyfile, because the caddy
# container may not exist yet.
if [ "$ACTIVE" != "none" ]; then
  write_caddyfile_only active_only
else
  # Bootstrap upstream so caddy can still serve /srv/web for ACME validation.
  write_caddyfile_only bootstrap
fi

log "bringing up infra (caddy + postgres + redis); compose --wait blocks on healthchecks"
IMAGE_CADDY_APP="$IMAGE_CADDY_APP" \
DB_PASSWORD="$DB_PASSWORD" \
  docker compose -f "$APP_DIR/compose.infra.yml" up -d --wait --wait-timeout 180 \
  || { fail "infra services failed healthcheck within 180s"; \
       docker logs --tail 50 postgres 2>&1 || true; \
       docker logs --tail 50 redis    2>&1 || true; \
       rollback; }

# ---- Stage 0: bring up canary ---------------------------------------------
log "stage 0: bringing up canary $NEW"
COLOR=$NEW \
IMAGE_API=$IMAGE_API IMAGE_WORKER=$IMAGE_WORKER \
DB_PASSWORD=$DB_PASSWORD \
WORKER_SECRET=$WORKER_SECRET \
GIT_SHA=$GIT_SHA BUILD_TIME=$BUILD_TIME \
  docker compose -f "$APP_DIR/compose.app.yml" -p "app-$NEW" up -d

log "waiting for canary api-$NEW /healthz"
wait_until "api-$NEW healthz" 30 2 api_color_healthy "$NEW" \
  || { fail "canary $NEW never became healthy"; rollback; }

log "direct /readyz on canary $NEW"
# Non-failing curl so we can show the body (tells us which check failed).
ready_resp=$(docker exec "api-$NEW" curl -sS --max-time 5 \
  -w '\nHTTP_STATUS=%{http_code}' "http://localhost:8080/readyz" 2>&1)
ready_status=$(printf '%s' "$ready_resp" | awk -F= '/^HTTP_STATUS=/{print $2}')
echo "$ready_resp"
echo
if [ "$ready_status" != "200" ]; then
  fail "/readyz failed on canary $NEW (status=$ready_status)"
  echo "--- api-$NEW logs (last 50) ---"
  docker logs --tail 50 "api-$NEW" 2>&1 || true
  echo "--- worker-$NEW logs (last 50) ---"
  docker logs --tail 50 "worker-$NEW" 2>&1 || true
  rollback
fi

log "direct /version on canary $NEW"
if ! probe_direct "$NEW" /version; then
  echo; fail "/version failed on canary $NEW"; rollback
fi
echo

log "direct /work on canary $NEW"
if ! probe_direct "$NEW" /work; then
  echo; fail "/work failed on canary $NEW"; rollback
fi
echo

# ---- Stages 1 + 2: weighted splits ----------------------------------------
# Probes /readyz (DB+Redis+worker) so a degraded downstream that returns
# 200 from /healthz still trips the gate.
if [ "$ACTIVE" != "none" ]; then
  log "stage 1: 90/10 split (active=$ACTIVE 90%, new=$NEW 10%)"
  render_caddyfile weighted 90 10
  caddy_settle
  probe_public 50 2 /readyz || { fail "stage 1 probe failed"; dump_diag; rollback; }

  log "stage 2: 50/50 split"
  render_caddyfile weighted 50 50
  caddy_settle
  probe_public 50 2 /readyz || { fail "stage 2 probe failed"; dump_diag; rollback; }
fi

# ---- Stage 3: promote -----------------------------------------------------
log "stage 3: promote $NEW to 100%"
render_caddyfile promote
caddy_settle
if ! probe_public 50 0 /readyz; then
  fail "stage 3 probe failed (post-promote)"
  dump_diag
  rollback
fi

# ---- Stage 4: tear down old -----------------------------------------------
if [ "$ACTIVE" != "none" ] && [ "$ACTIVE" != "$NEW" ]; then
  log "stage 4: tearing down $ACTIVE"
  COLOR=$ACTIVE docker compose -f "$APP_DIR/compose.app.yml" -p "app-$ACTIVE" \
    down --remove-orphans 2>/dev/null || true
fi

gcs_write_active "$NEW"
log "promoted $NEW; previous=$ACTIVE torn down; active.color saved to gs://${DEPLOY_STATE_BUCKET}/active.color"
