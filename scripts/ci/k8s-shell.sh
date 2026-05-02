#!/usr/bin/env bash
# Fast local kubectl: grab the k3s admin kubeconfig over IAP-tunneled SSH,
# rewrite the server URL to the local tunnel, and open a tunnel + child
# shell with KUBECONFIG pointed at it.
#
# Use this for debugging — not for CI. CI uses scripts/ci/k8s-auth.sh,
# which authenticates as the k8s-deployer SA via OIDC (RBAC-scoped). This
# script gives full cluster-admin via the bootstrap admin kubeconfig.
#
# When you exit the spawned shell, the tunnel is killed.
#
# Requires that you're a member of the project (any IAM that lets you
# `gcloud compute ssh --tunnel-through-iap` to the server). No SA
# impersonation needed.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

# Resolve outputs from local TF state (no GCP_* env required).
SERVER=$(terraform -chdir="$TF_MAIN" output -raw k3s_server_name)
ZONE=$(terraform -chdir="$TF_MAIN" output -raw k3s_server_zone)
LOCAL_PORT=${LOCAL_PORT:-6443}
KCFG=$(mktemp -t k8s-shell-kcfg.XXXXXX)
trap 'rm -f "$KCFG"' EXIT

log "fetching admin kubeconfig from $SERVER"
gcloud compute ssh "$SERVER" --zone="$ZONE" --tunnel-through-iap --quiet \
  --command="sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed -e "s|https://127.0.0.1:6443|https://127.0.0.1:$LOCAL_PORT|" \
  > "$KCFG"

log "starting IAP tunnel $SERVER:6443 -> 127.0.0.1:$LOCAL_PORT"
gcloud compute start-iap-tunnel "$SERVER" 6443 \
  --local-host-port="127.0.0.1:$LOCAL_PORT" \
  --zone="$ZONE" >/tmp/k8s-shell-iap.log 2>&1 &
TUNNEL_PID=$!
trap 'kill $TUNNEL_PID 2>/dev/null; rm -f "$KCFG"' EXIT

wait_until "IAP tunnel bound" 30 1 \
  bash -c "exec 3<>/dev/tcp/127.0.0.1/$LOCAL_PORT && exec 3<&- && exec 3>&-" \
  || { cat /tmp/k8s-shell-iap.log; fail "tunnel never came up"; }

log "kubectl ready (cluster-admin). exit shell to tear down tunnel."
export KUBECONFIG="$KCFG"
PS1='[k8s-shell] \w\$ ' exec "${SHELL:-bash}"
