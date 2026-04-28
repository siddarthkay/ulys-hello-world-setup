#!/usr/bin/env bash
# Post terraform/main/plan.txt as a PR comment via the GitHub API.
# Required env: GITHUB_TOKEN, GITHUB_REPO, PR_NUMBER
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env GITHUB_TOKEN
need_env GITHUB_REPO
need_env PR_NUMBER

PLAN_FILE=$TF_MAIN/plan.txt
[ -s "$PLAN_FILE" ] || fail "no plan at $PLAN_FILE"

# GitHub caps comments at 65536 chars; trim to stay under.
plan=$(tail -c 60000 "$PLAN_FILE")

body=$(jq -Rn --arg p "$plan" '{ body: ("### Terraform plan\n\n```\n" + $p + "\n```") }')

curl -fsS \
  -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$body" \
  "https://api.github.com/repos/$GITHUB_REPO/issues/$PR_NUMBER/comments" \
  >/dev/null

log "posted plan comment to PR #$PR_NUMBER"
