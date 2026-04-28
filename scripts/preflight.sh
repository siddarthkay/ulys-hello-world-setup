#!/usr/bin/env bash
# Validates the local environment is ready to run the bootstrap.
# Run this before `terraform apply` in terraform/bootstrap/.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yel()   { printf '\033[33m%s\033[0m\n' "$*"; }

fail=0

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    green "  OK    $name"
  else
    red   "  FAIL  $name"
    fail=$((fail + 1))
  fi
}

echo "Preflight checks:"

check "gcloud installed"           command -v gcloud
check "terraform >= 1.6"           bash -c 'v=$(terraform version -json | grep -o "\"terraform_version\": \"[^\"]*\"" | cut -d\" -f4); printf "%s\n%s\n" "1.6.0" "$v" | sort -V -C'
check "jq installed"               command -v jq
check "gcloud authenticated"       bash -c '[ -n "$(gcloud auth list --filter=status:ACTIVE --format="value(account)")" ]'
check "gcloud project set"         bash -c '[ -n "$(gcloud config get-value project 2>/dev/null)" ]'

PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [ -n "$PROJECT" ]; then
  check "billing enabled on $PROJECT" bash -c "gcloud beta billing projects describe $PROJECT --format='value(billingEnabled)' | grep -q True"
fi

echo
if [ "$fail" -gt 0 ]; then
  red "$fail check(s) failed. Fix and re-run."
  exit 1
fi

green "All preflight checks passed."

# Print the values you'll need for terraform.tfvars
echo
yel "Values to plug into terraform/bootstrap/terraform.tfvars:"
echo "  project_id         = \"$PROJECT\""
echo "  project_number     = \"$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')\""
echo "  region             = \"us-central1\""
echo "  state_bucket_name  = \"${PROJECT}-tfstate\""
echo "  github_repo        = \"<owner>/<repo>\"            # fill in"
echo "  billing_account_id = \"$(gcloud beta billing accounts list --filter=open=true --format='value(name)' --limit=1 | awk -F/ '{print $2}')\""
echo "  budget_alert_email = \"<your_email>\"              # fill in"
