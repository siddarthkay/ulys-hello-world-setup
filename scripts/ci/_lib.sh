# shellcheck shell=bash
# Helpers shared by scripts/ci/*.sh AND scripts/all-bootstrap.sh.
# Source-only; not executable. Each consumer is responsible for its own
# `set -euo pipefail` (we don't mutate the caller's shell options).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TF_MAIN=$ROOT/terraform/main
TF_BOOTSTRAP=$ROOT/terraform/bootstrap

log()  { printf '\n>>> %s\n' "$*"; }
warn() { printf '\n--- %s\n' "$*"; }
fail() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# Require an env var; fail with a useful message if missing.
need_env() {
  local var=$1 hint=${2:-}
  if [ -z "${!var:-}" ]; then
    fail "missing required env var: $var${hint:+ ($hint)}"
  fi
}

# Poll a predicate up to N times with a fixed sleep between attempts.
# Usage: wait_until <description> <max_attempts> <sleep_seconds> <command...>
# Returns 0 on first successful predicate, 1 on exhaustion.
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

# TF_VAR_* env vars terraform/main expects.
# Region must be threaded explicitly: relying on the variable default
# would silently move every regional resource if the bootstrap-chosen
# region differed from the code default. Zone is derived from region
# inside Terraform (see terraform/main/locals.tf), so no GCP_ZONE.
export_tf_vars() {
  need_env GCP_PROJECT_ID
  need_env GCP_GHA_SA_EMAIL
  need_env GCP_REGION
  export TF_VAR_project_id="$GCP_PROJECT_ID"
  export TF_VAR_gha_service_account_email="$GCP_GHA_SA_EMAIL"
  export TF_VAR_region="$GCP_REGION"
}
