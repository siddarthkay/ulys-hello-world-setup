#!/usr/bin/env bash
# Ordered, safe teardown. Tee the output to docs/destroy.txt so you can include
# it in your submission.
#
# Order: main → secrets versions → bootstrap → state bucket
#
#   1. `terraform destroy` in main (VM, Cloud SQL, Memorystore, AR, Secret
#      Manager containers, IAM bindings)
#   2. bootstrap (state bucket, WIF, GHA SA, budget, APIs)
#   3. final manual sweep of the state bucket (versioned objects don't get
#      removed by `terraform destroy` and would block deleting the bucket
#      next time you re-bootstrap into the same project)
#
# Pass --keep-bootstrap to stop after step 1 (useful if you want to re-deploy).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP=$ROOT/terraform/bootstrap
MAIN=$ROOT/terraform/main
DOCS=$ROOT/docs
mkdir -p "$DOCS"

KEEP_BOOTSTRAP=0
for a in "$@"; do [ "$a" = "--keep-bootstrap" ] && KEEP_BOOTSTRAP=1; done

LOG=$DOCS/destroy.txt
: > "$LOG"

echo "=== terraform destroy: main ===" | tee -a "$LOG"
cd "$MAIN"
terraform destroy -auto-approve | tee -a "$LOG"

if [ "$KEEP_BOOTSTRAP" = "1" ]; then
  echo "--keep-bootstrap supplied; skipping bootstrap destroy" | tee -a "$LOG"
  exit 0
fi

echo "=== terraform destroy: bootstrap ===" | tee -a "$LOG"
cd "$BOOTSTRAP"
STATE_BUCKET=$(terraform output -raw state_bucket 2>/dev/null || true)
PROJECT=$(grep '^project_id' "$BOOTSTRAP/terraform.tfvars" | cut -d'"' -f2 2>/dev/null || true)

terraform destroy -auto-approve | tee -a "$LOG" || true

if [ -n "$STATE_BUCKET" ] && [ -n "$PROJECT" ]; then
  echo "=== final sweep: empty + delete state bucket $STATE_BUCKET ===" | tee -a "$LOG"
  gcloud storage rm -r --recursive "gs://$STATE_BUCKET" --project "$PROJECT" 2>&1 | tee -a "$LOG" || true
fi

echo "=== done. log at $LOG ===" | tee -a "$LOG"
