# shellcheck shell=bash
# Common helpers for scripts/ci/*.sh
# Intentionally not executable — `source`d by the others.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TF_MAIN=$ROOT/terraform/main
TF_BOOTSTRAP=$ROOT/terraform/bootstrap

log()  { printf '\n>>> %s\n' "$*"; }
fail() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# Hard-require an env var; print a useful message if missing.
need_env() {
  local var=$1 hint=${2:-}
  if [ -z "${!var:-}" ]; then
    fail "missing required env var: $var${hint:+ — $hint}"
  fi
}

# Export TF_VAR_* env vars main/ expects, derived from the canonical names
# used by CI + local dev.
export_tf_vars() {
  need_env GCP_PROJECT_ID
  need_env GCP_WIF_PROVIDER
  need_env GCP_GHA_SA_EMAIL
  need_env GITHUB_REPO "set to <owner>/<repo> when running locally"
  export TF_VAR_project_id="$GCP_PROJECT_ID"
  export TF_VAR_github_repo="$GITHUB_REPO"
  export TF_VAR_wif_provider="$GCP_WIF_PROVIDER"
  export TF_VAR_gha_service_account_email="$GCP_GHA_SA_EMAIL"
}
