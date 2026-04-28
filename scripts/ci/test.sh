#!/usr/bin/env bash
# Run pytest against api and worker. Both modules are named app.py so we run
# them in separate processes to avoid sys.modules collisions.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

cd "$ROOT"

if [ -z "${SKIP_INSTALL:-}" ]; then
  log "installing test deps"
  python -m pip install -q -U pip
  pip install -q -r app/api/requirements.txt -r app/worker/requirements.txt pytest
fi

log "pytest app/api"
( cd app/api    && pytest -q )

log "pytest app/worker"
( cd app/worker && pytest -q )
