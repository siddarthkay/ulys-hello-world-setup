#!/usr/bin/env bash
# Sync app/web/ into the static-site bucket. Cloud CDN auto-invalidates on
# object overwrite for cache_mode=CACHE_ALL_STATIC, so a fresh index.html
# starts serving on the next user request after upload.
#
# Required env: WEB_BUCKET
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env WEB_BUCKET

log "uploading $ROOT/app/web/ -> gs://$WEB_BUCKET/"
gcloud storage rsync "$ROOT/app/web/" "gs://$WEB_BUCKET/" \
  --recursive --delete-unmatched-destination-objects --quiet

log "invalidating Cloud CDN cache for index.html"
# CDN cache invalidation is async; we don't block on it. Without explicit
# invalidation, edge nodes serve the previous index.html until the cached
# entry's max-age expires (default 1h via cdn_policy default_ttl).
gcloud compute url-maps invalidate-cdn-cache \
  "${URL_MAP_NAME:-ulys-url-map}" \
  --path="/" --async --quiet 2>/dev/null \
  || warn "cache invalidation skipped (URL map missing or insufficient perms; CDN will serve old index.html for up to 1h)"

log "web upload complete"
