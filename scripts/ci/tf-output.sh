#!/usr/bin/env bash
# Emit terraform outputs as `key=value` lines on stdout.
# Workflows redirect this to $GITHUB_OUTPUT; locally you can `eval $(make tf-output)`.
source "$(dirname "$0")/_lib.sh"

# Single jq pass over `terraform output -json` keeps it cheap (one TF invocation).
terraform -chdir="$TF_MAIN" output -json | jq -r '
  to_entries
  | map(select(.value.sensitive == false))
  | .[]
  | "\(.key)=\(.value.value)"
'
