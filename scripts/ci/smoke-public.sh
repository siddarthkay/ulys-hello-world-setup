#!/usr/bin/env bash
# Final post-promote check: hit the public HTTPS endpoint /api/version.
# Required env: DOMAIN
source "$(dirname "$0")/_lib.sh"
need_env DOMAIN

log "post-deploy verification: https://$DOMAIN/api/version"
for i in $(seq 1 20); do
  if curl -fsSk --max-time 5 "https://$DOMAIN/api/version"; then
    echo
    log "public endpoint OK"
    exit 0
  fi
  printf '  retry %d/20\n' "$i"
  sleep 5
done
fail "public HTTPS endpoint did not respond after promote"
