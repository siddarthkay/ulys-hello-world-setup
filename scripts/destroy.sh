#!/usr/bin/env bash
# Ordered teardown: main, then bootstrap, then a final state-bucket sweep.
# Output is tee'd to docs/destroy.txt for the submission.
#
# Pass --keep-bootstrap to stop after main (useful for a quick re-deploy).

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

# Empty the static-site bucket so terraform destroy can delete it.
# force_destroy=true on the bucket also handles this, but emptying first
# avoids "bucket not empty" errors on bucket recreation churn.
WEB_BUCKET=$(terraform output -raw web_bucket 2>/dev/null || true)
if [ -n "$WEB_BUCKET" ]; then
  echo "--- pre-destroy: empty web bucket gs://$WEB_BUCKET ---" | tee -a "$LOG"
  gcloud storage rm --recursive "gs://$WEB_BUCKET/**" 2>&1 | tee -a "$LOG" || true
fi

echo "--- pre-destroy: reconcile state (clears deletion_protection flags) ---" | tee -a "$LOG"
terraform apply -auto-approve 2>&1 | tee -a "$LOG"

terraform destroy -auto-approve | tee -a "$LOG"

if [ "$KEEP_BOOTSTRAP" = "1" ]; then
  echo "--keep-bootstrap supplied; skipping bootstrap destroy" | tee -a "$LOG"
  exit 0
fi

echo "=== terraform destroy: bootstrap ===" | tee -a "$LOG"
cd "$BOOTSTRAP"
# Prefer terraform outputs; fall back to grepping tfvars when an output
# isn't defined (older state files predate the project_id output, or the
# user is destroying state that was never re-applied with this code).
read_var() {
  local out_name=$1 var_name=$2
  terraform output -raw "$out_name" 2>/dev/null \
    || grep "^${var_name}" terraform.tfvars 2>/dev/null | head -1 | cut -d'"' -f2 \
    || true
}
STATE_BUCKET=$(read_var state_bucket state_bucket_name)
PROJECT=$(read_var project_id project_id)

terraform destroy -auto-approve | tee -a "$LOG" || true

# Versioned objects in the state bucket aren't removed by `terraform destroy`,
# so the bucket itself can't be deleted. Sweep them manually.
if [ -n "$STATE_BUCKET" ] && [ -n "$PROJECT" ]; then
  echo "=== final sweep: empty + delete state bucket $STATE_BUCKET ===" | tee -a "$LOG"
  gcloud storage rm --recursive "gs://$STATE_BUCKET" --project "$PROJECT" 2>&1 | tee -a "$LOG" || true
fi

echo "=== done. log at $LOG ===" | tee -a "$LOG"
