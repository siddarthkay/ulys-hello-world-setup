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

# Fill GCP_* env vars from sources, in priority order:
#   1. existing env (CI sets them from secrets; no-op).
#   2. bootstrap TF state outputs (works after `make all-bootstrap`).
#   3. interactive prompt (local convenience, like all-bootstrap.sh).
#
# Region falls back to gcloud config or "us-central1". TTY guard means CI
# (no tty) errors out cleanly with `need_env` instead of hanging on read.
ensure_gcp_env() {
  if [ -z "${GCP_PROJECT_ID:-}${GCP_TF_STATE_BUCKET:-}${GCP_GHA_SA_EMAIL:-}${GCP_REGION:-}" ] \
      && [ -d "$TF_BOOTSTRAP/.terraform" ]; then
    local out
    if out=$(terraform -chdir="$TF_BOOTSTRAP" output -json 2>/dev/null) && [ -n "$out" ]; then
      : "${GCP_PROJECT_ID:=$(echo "$out"     | jq -r '.project_id.value                // empty')}"
      : "${GCP_TF_STATE_BUCKET:=$(echo "$out" | jq -r '.state_bucket.value              // empty')}"
      : "${GCP_GHA_SA_EMAIL:=$(echo "$out"   | jq -r '.gha_service_account_email.value // empty')}"
    fi
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    local v
    if [ -z "${GCP_PROJECT_ID:-}" ]; then
      local def; def=$(gcloud config get-value project 2>/dev/null || true)
      read -r -p "  GCP project ID${def:+ [$def]}: " v; GCP_PROJECT_ID=${v:-$def}
    fi
    if [ -z "${GCP_REGION:-}" ]; then
      local def; def=$(gcloud config get-value compute/region 2>/dev/null || true); def=${def:-us-central1}
      read -r -p "  Region [$def]: " v; GCP_REGION=${v:-$def}
    fi
    if [ -z "${GCP_TF_STATE_BUCKET:-}" ]; then
      local def="${GCP_PROJECT_ID}-tfstate"
      read -r -p "  TF state bucket [$def]: " v; GCP_TF_STATE_BUCKET=${v:-$def}
    fi
    if [ -z "${GCP_GHA_SA_EMAIL:-}" ]; then
      local def="ulys-gha@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
      read -r -p "  GHA SA email [$def]: " v; GCP_GHA_SA_EMAIL=${v:-$def}
    fi
  fi

  export GCP_PROJECT_ID GCP_TF_STATE_BUCKET GCP_GHA_SA_EMAIL GCP_REGION
  need_env GCP_PROJECT_ID
  need_env GCP_TF_STATE_BUCKET
  need_env GCP_GHA_SA_EMAIL
  need_env GCP_REGION
}

# TF_VAR_* env vars terraform/main expects. Region must be threaded
# explicitly: relying on the variable default would silently move every
# regional resource if the bootstrap-chosen region differed from the code
# default. Zone is derived from region inside Terraform (see
# terraform/main/locals.tf), so no GCP_ZONE.
export_tf_vars() {
  ensure_gcp_env
  export TF_VAR_project_id="$GCP_PROJECT_ID"
  export TF_VAR_gha_service_account_email="$GCP_GHA_SA_EMAIL"
  export TF_VAR_region="$GCP_REGION"
}
