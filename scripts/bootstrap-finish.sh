#!/usr/bin/env bash
# Run AFTER `terraform apply` in terraform/bootstrap/ AND once after the FIRST
# `terraform apply` in terraform/main/ (to populate Secret Manager + the Cloud
# SQL user password).
#
# What it does:
#   1. emits terraform/main/terraform.tfvars from bootstrap outputs (so the
#      next `terraform init` / `apply` in main/ has values plugged in)
#   2. lists the GitHub Actions secrets to add to the repo
#   3. on the second pass (when main/ has been applied at least once):
#      a. generates a strong DB password and worker secret (locally, never
#         echoed)
#      b. writes them as new versions to Secret Manager
#      c. sets the Cloud SQL user's password via `gcloud sql users set-password`
#
# Idempotent: re-running (3) creates new secret versions but the VM only ever
# reads `latest`, so this is safe to re-run for rotation.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP=$ROOT/terraform/bootstrap
MAIN=$ROOT/terraform/main

cd "$BOOTSTRAP"
STATE_BUCKET=$(terraform output -raw state_bucket)
WIF_PROVIDER=$(terraform output -raw wif_provider)
GHA_SA=$(terraform output -raw gha_service_account_email)

cd "$ROOT"
PROJECT=$(grep '^project_id' "$BOOTSTRAP/terraform.tfvars" | cut -d'"' -f2)
REPO=$(grep '^github_repo' "$BOOTSTRAP/terraform.tfvars" | cut -d'"' -f2)
NAME_PREFIX=ulys

cat > "$MAIN/terraform.tfvars" <<EOF
project_id                = "$PROJECT"
region                    = "us-central1"
zone                      = "us-central1-a"
name_prefix               = "$NAME_PREFIX"
github_repo               = "$REPO"
wif_provider              = "$WIF_PROVIDER"
gha_service_account_email = "$GHA_SA"
vm_machine_type           = "e2-micro"
EOF
echo "wrote $MAIN/terraform.tfvars"

cat <<EOF

==== Add these as GitHub repo secrets (Settings -> Secrets and variables -> Actions) ====

  GCP_PROJECT_ID         = $PROJECT
  GCP_TF_STATE_BUCKET    = $STATE_BUCKET
  GCP_WIF_PROVIDER       = $WIF_PROVIDER
  GCP_GHA_SA_EMAIL       = $GHA_SA

EOF

# Try to populate Secret Manager + Cloud SQL — only works after `terraform
# apply` in main/ has run at least once.
DB_SECRET="${NAME_PREFIX}-db-password"
WS_SECRET="${NAME_PREFIX}-worker-secret"
DB_INSTANCE="${NAME_PREFIX}-pg"

if ! gcloud secrets describe "$DB_SECRET" --project "$PROJECT" >/dev/null 2>&1; then
  cat <<EOF
Skipping secret population — Secret Manager resources not yet created.
After your first \`terraform apply\` in $MAIN/, re-run this script to
populate secrets and set the Cloud SQL user password.
EOF
  exit 0
fi

DB_PASS=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)
WS=$(openssl rand -hex 32)

printf '%s' "$DB_PASS" | gcloud secrets versions add "$DB_SECRET" --data-file=- --project "$PROJECT" >/dev/null
printf '%s' "$WS"      | gcloud secrets versions add "$WS_SECRET" --data-file=- --project "$PROJECT" >/dev/null
echo "added new versions to Secret Manager: $DB_SECRET, $WS_SECRET"

gcloud sql users set-password app \
  --instance "$DB_INSTANCE" \
  --password "$DB_PASS" \
  --project "$PROJECT" >/dev/null
echo "set password on Cloud SQL user 'app' in instance $DB_INSTANCE"

unset DB_PASS WS
echo "done."
