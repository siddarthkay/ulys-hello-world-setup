#!/usr/bin/env bash
# Final post-promote check: hit the public HTTPS endpoint /api/version.
# Required env: DOMAIN
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env DOMAIN

probe() { curl -fsS --max-time 5 "https://$DOMAIN/api/version"; }

log "post-deploy verification: https://$DOMAIN/api/version"
wait_until "public /api/version" 20 5 probe \
  || fail "public HTTPS endpoint did not respond after promote"
echo
log "public endpoint OK"
