#!/usr/bin/env bash
# One-shot orchestrator: fresh GCP project + GitHub repo to fully deployed.
# Idempotent. Re-runs rotate secrets, re-apply Terraform (no-op if no drift),
# and re-set the GitHub Actions secrets.
#
# Steps:
#   1. validate prereqs
#   2. collect inputs (defaults from gcloud config + git remote)
#   3. write terraform/bootstrap/terraform.tfvars
#   4. terraform apply bootstrap
#   5. write Secret Manager values (DB password, worker secret)
#   6. set the four GitHub Actions secrets via `gh secret set`
#   7. write terraform/main/terraform.tfvars
#   8. terraform apply main
#   9. print URLs
#
# Architecture: Cloud Run (api, worker), Cloud SQL HA Postgres, Memorystore
# Standard Redis, GCS+CDN+HTTPS LB for the static site. Cloud SQL HA
# provisioning is the long wait at ~10 minutes; the LB-cert provisioning is
# async (managed cert may take 15-30 min to go ACTIVE after first apply).

set -euo pipefail

# Shared helpers (log, warn, fail, need_env, wait_until). Defines ROOT,
# TF_MAIN, TF_BOOTSTRAP. We re-bind to the local var names for readability.
# shellcheck source=scripts/ci/_lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ci/_lib.sh"

BOOTSTRAP=$TF_BOOTSTRAP
MAIN=$TF_MAIN
NAME_PREFIX=ulys

# `die` is the historical name in this script; `fail` from _lib.sh is identical.
die() { fail "$@"; }

ask() {
  local var=$1 prompt=$2 default=${3:-}
  local v
  if [ -n "$default" ]; then
    read -r -p "  $prompt [$default]: " v
    printf -v "$var" '%s' "${v:-$default}"
  else
    read -r -p "  $prompt: " v
    printf -v "$var" '%s' "$v"
  fi
}

# --- 1. Validate prereqs ----------------------------------------------------
log "checking prerequisites"
for cmd in gcloud terraform gh openssl jq; do
  command -v "$cmd" >/dev/null || die "$cmd not found in PATH"
done

[ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ] \
  || die "gcloud not authenticated. Run: gcloud auth login && gcloud auth application-default login"

gh auth status >/dev/null 2>&1 \
  || die "gh CLI not authenticated. Run: gh auth login"

# --- 2. Collect inputs ------------------------------------------------------
log "collecting inputs (Enter to accept the default in [brackets])"

DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
DEFAULT_REPO=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's#(git@github\.com:|https://github\.com/)([^/]+/[^/]+)(\.git)?#\2#' \
  | sed -E 's#\.git$##' || true)
DEFAULT_BILLING=$(gcloud beta billing accounts list --filter=open=true \
  --format='value(name)' --limit=1 2>/dev/null | awk -F/ '{print $2}' || true)

ask PROJECT_ID    "GCP project ID"            "$DEFAULT_PROJECT"
[ -n "$PROJECT_ID" ] || die "project ID is required"
DEFAULT_PNUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
ask PROJECT_NUMBER "GCP project number"       "$DEFAULT_PNUM"
ask GITHUB_REPO   "GitHub repo (owner/name)"  "$DEFAULT_REPO"
ask BILLING_ID    "Billing account ID"        "$DEFAULT_BILLING"
ask ALERT_EMAIL   "Budget alert email"        ""
ask REGION        "Region"                    "us-central1"

# Zone is no longer collected here. terraform/main derives it from the
# region via `data "google_compute_zones"`, so local apply and CI apply
# always pick the same zone for a given region.

[ -n "$ALERT_EMAIL" ]    || die "alert email required"
[ -n "$GITHUB_REPO" ]    || die "github repo required"
[ -n "$BILLING_ID" ]     || die "billing account required"
[ -n "$PROJECT_NUMBER" ] || die "project number required"

# billingbudgets API rejects user-cred calls without a quota project.
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null 2>&1 || \
  warn "could not set ADC quota project (run 'gcloud auth application-default login' if bootstrap apply fails on billingbudgets)"

# --- 3. Write bootstrap tfvars ----------------------------------------------
log "writing $BOOTSTRAP/terraform.tfvars"
cat > "$BOOTSTRAP/terraform.tfvars" <<EOF
project_id         = "$PROJECT_ID"
project_number     = "$PROJECT_NUMBER"
region             = "$REGION"
state_bucket_name  = "$PROJECT_ID-tfstate"
github_repo        = "$GITHUB_REPO"
billing_account_id = "$BILLING_ID"
budget_alert_email = "$ALERT_EMAIL"
EOF

# --- 4. Apply bootstrap -----------------------------------------------------
log "terraform apply (bootstrap): state bucket, WIF, GHA SA, budget"
terraform -chdir="$BOOTSTRAP" init -input=false -upgrade

# Reconcile soft-deleted resources from a previous bootstrap so re-create
# doesn't 409. GCP keeps WIF pools/providers and service accounts in a
# 30-day soft-delete state after `terraform destroy`. Errors here are
# best-effort: every command is guarded so script-wide `set -e` stays on.
log "reconciling any soft-deleted resources from previous bootstraps"

POOL_ID="${NAME_PREFIX}-github-pool"
PROV_ID="${NAME_PREFIX}-github-provider"
SA_EMAIL="${NAME_PREFIX}-gha@${PROJECT_ID}.iam.gserviceaccount.com"

reconcile() {
  local addr=$1 id=$2 desc=$3 undel=$4

  if terraform -chdir="$BOOTSTRAP" state list 2>/dev/null | grep -qFx "$addr"; then
    return 0
  fi

  local state
  state=$(eval "$desc --format='value(state)'" 2>/dev/null || true)
  [ -n "$state" ] || return 0

  if [ "$state" = "DELETED" ]; then
    echo "  reconcile: $addr soft-deleted, undeleting"
    if ! eval "$undel" 2>&1 | sed 's/^/    /'; then
      warn "  undelete returned non-zero (continuing anyway)"
    fi
    sleep 5
  else
    echo "  reconcile: $addr exists (state=$state), importing"
  fi

  if terraform -chdir="$BOOTSTRAP" import "$addr" "$id" 2>&1 | sed 's/^/    /'; then
    echo "  reconcile: imported $addr OK"
  else
    warn "  import of $addr failed (bootstrap apply will 409 if not resolved)"
  fi
}

reconcile \
  'google_iam_workload_identity_pool.github' \
  "projects/${PROJECT_ID}/locations/global/workloadIdentityPools/${POOL_ID}" \
  "gcloud iam workload-identity-pools describe ${POOL_ID} --location=global --project=${PROJECT_ID}" \
  "gcloud iam workload-identity-pools undelete ${POOL_ID} --location=global --project=${PROJECT_ID} --quiet"

reconcile \
  'google_iam_workload_identity_pool_provider.github' \
  "projects/${PROJECT_ID}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROV_ID}" \
  "gcloud iam workload-identity-pools providers describe ${PROV_ID} --location=global --workload-identity-pool=${POOL_ID} --project=${PROJECT_ID}" \
  "gcloud iam workload-identity-pools providers undelete ${PROV_ID} --location=global --workload-identity-pool=${POOL_ID} --project=${PROJECT_ID} --quiet"

# Service accounts: `describe` returns 404 on a deleted SA, so list with
# --show-deleted and undelete by uniqueId.
if ! terraform -chdir="$BOOTSTRAP" state list 2>/dev/null | grep -qFx 'google_service_account.gha'; then
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "  reconcile: GHA service account exists, importing"
    terraform -chdir="$BOOTSTRAP" import google_service_account.gha \
      "projects/${PROJECT_ID}/serviceAccounts/${SA_EMAIL}" 2>&1 | sed 's/^/    /' || \
      warn "  GHA SA import failed"
  else
    SA_LIST=$(gcloud iam service-accounts list \
      --filter="email:${SA_EMAIL}" --show-deleted \
      --format='value(uniqueId)' --project="$PROJECT_ID" 2>/dev/null || true)
    SA_UID=${SA_LIST%%$'\n'*}
    if [ -n "$SA_UID" ]; then
      echo "  reconcile: GHA service account soft-deleted (uid=$SA_UID), undeleting"
      gcloud iam service-accounts undelete "$SA_UID" --project="$PROJECT_ID" --quiet 2>&1 | sed 's/^/    /'
      sleep 5
      terraform -chdir="$BOOTSTRAP" import google_service_account.gha \
        "projects/${PROJECT_ID}/serviceAccounts/${SA_EMAIL}" 2>&1 | sed 's/^/    /' || \
        warn "  GHA SA import failed after undelete"
    fi
  fi
fi

# State bucket: import if it exists in GCP but not in TF state.
if ! terraform -chdir="$BOOTSTRAP" state list 2>/dev/null | grep -qFx 'google_storage_bucket.tfstate'; then
  if gcloud storage buckets describe "gs://${PROJECT_ID}-tfstate" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "  reconcile: state bucket exists, importing"
    terraform -chdir="$BOOTSTRAP" import google_storage_bucket.tfstate \
      "${PROJECT_ID}-tfstate" 2>&1 | sed 's/^/    /' || warn "  state bucket import failed"
  fi
fi

terraform -chdir="$BOOTSTRAP" apply -input=false -auto-approve

STATE_BUCKET=$(terraform -chdir="$BOOTSTRAP" output -raw state_bucket)
WIF_PROVIDER=$(terraform -chdir="$BOOTSTRAP" output -raw wif_provider)
GHA_SA_EMAIL=$(terraform -chdir="$BOOTSTRAP" output -raw gha_service_account_email)

# --- 5. Populate Secret Manager values --------------------------------------
# Only the DB password lives in SM. api -> worker auth uses Google ID tokens
# (verified by the worker), no shared secret needed.
log "creating + populating Secret Manager values"
DB_SECRET="${NAME_PREFIX}-db-password"

gcloud secrets describe "$DB_SECRET" --project "$PROJECT_ID" >/dev/null 2>&1 || {
  echo "  creating secret container: $DB_SECRET"
  gcloud secrets create "$DB_SECRET" --project "$PROJECT_ID" --replication-policy=automatic >/dev/null
}

DB_PASS=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)

printf '%s' "$DB_PASS" | gcloud secrets versions add "$DB_SECRET" --data-file=- --project "$PROJECT_ID" >/dev/null
echo "  added new version to $DB_SECRET"

# --- 6. Set GitHub Actions repo secrets ------------------------------------
log "setting GitHub Actions secrets via gh"
gh secret set GCP_PROJECT_ID      --repo "$GITHUB_REPO" --body "$PROJECT_ID"   >/dev/null
gh secret set GCP_TF_STATE_BUCKET --repo "$GITHUB_REPO" --body "$STATE_BUCKET" >/dev/null
gh secret set GCP_WIF_PROVIDER    --repo "$GITHUB_REPO" --body "$WIF_PROVIDER" >/dev/null
gh secret set GCP_GHA_SA_EMAIL    --repo "$GITHUB_REPO" --body "$GHA_SA_EMAIL" >/dev/null
# Region is threaded as a secret so CI's TF_VAR_region matches the
# bootstrap-chosen value instead of falling back to the variable default
# (which would silently move every regional resource). Not sensitive; we
# use a secret for symmetry with the four above. Zone is derived from
# region inside terraform/main, so no GCP_ZONE here.
gh secret set GCP_REGION          --repo "$GITHUB_REPO" --body "$REGION"       >/dev/null
echo "  set GCP_PROJECT_ID, GCP_TF_STATE_BUCKET, GCP_WIF_PROVIDER, GCP_GHA_SA_EMAIL, GCP_REGION on $GITHUB_REPO"

# --- 7. Write main tfvars ---------------------------------------------------
log "writing $MAIN/terraform.tfvars"
cat > "$MAIN/terraform.tfvars" <<EOF
project_id                = "$PROJECT_ID"
region                    = "$REGION"
gha_service_account_email = "$GHA_SA_EMAIL"
EOF

# --- 8. Apply main TF -------------------------------------------------------
# Cloud SQL HA provisioning is ~10 min. LB managed cert provisioning is
# async; even after apply succeeds, the cert may sit in PROVISIONING for
# 15-30 minutes before going ACTIVE. The HTTPS endpoint returns cert
# errors until then.
log "terraform apply (main): VPC, Cloud SQL HA (REGIONAL, PITR), Memorystore, Cloud Run, LB."
log "  Cloud SQL HA takes ~10 min to provision. Total apply ~12-15 min."
terraform -chdir="$MAIN" init  -input=false -reconfigure -backend-config="bucket=$STATE_BUCKET"
terraform -chdir="$MAIN" apply -input=false -auto-approve

# --- 9. Rotate Cloud SQL user password to the SM value ----------------------
# Cloud SQL requires a password at user creation; main TF uses a transient
# random_password (which would land in state) and rotates it here to the SM
# value. Subsequent applies are no-op for the password thanks to
# ignore_changes = [password] on google_sql_user.app.
DB_INSTANCE=$(terraform -chdir="$MAIN" output -raw db_instance_name)
log "rotating Cloud SQL 'app' user password on instance $DB_INSTANCE"
gcloud sql users set-password app \
  --instance "$DB_INSTANCE" \
  --password "$DB_PASS" \
  --project "$PROJECT_ID" >/dev/null
echo "  rotated."

unset DB_PASS

# --- 10. Done ---------------------------------------------------------------
DOMAIN=$(terraform -chdir="$MAIN" output -raw domain)
LB_IP=$(terraform -chdir="$MAIN" output -raw lb_ip)
log "all-bootstrap complete"
cat <<EOF

  Web URL: https://$DOMAIN
  API:     https://$DOMAIN/api
  LB IP:   $LB_IP

  TLS note: Google-managed cert for $DOMAIN may take 15-30 minutes to
  go ACTIVE. Until then, HTTPS will show cert errors. Verify via:
    gcloud compute ssl-certificates describe ${NAME_PREFIX}-cert \\
      --global --format='value(managed.status,managed.domainStatus)'

  Next: push to main to trigger the first CI deploy.
        git push -u origin main
EOF
