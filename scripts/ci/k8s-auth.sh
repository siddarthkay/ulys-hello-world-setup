#!/usr/bin/env bash
# Bring up an authenticated kubectl context against the k3s cluster.
#
# Auth chain:
#   1. GHA already authed to GCP via WIF (google-github-actions/auth).
#   2. Impersonate k8s_deployer SA -> mint a Google-issued OIDC ID token
#      with audience = the k8s API server's expected client_id (the SA's
#      own email, see kube-apiserver --oidc-client-id in cloud-config-server).
#   3. Open IAP TCP tunnel to the k3s server's 6443 (server has no public
#      6443 firewall ingress).
#   4. Write a kubeconfig pointing at 127.0.0.1:6443 with the ID token.
#
# Required env:
#   K3S_SERVER_NAME, K3S_SERVER_ZONE, K8S_DEPLOYER_SA_EMAIL
#
# Side effects:
#   - Spawns a background `gcloud compute start-iap-tunnel`. Caller is
#     expected to run within the same job; the tunnel dies with the runner.
#   - Writes ./kubeconfig and exports KUBECONFIG to point at it.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env K3S_SERVER_NAME
need_env K3S_SERVER_ZONE
need_env K8S_DEPLOYER_SA_EMAIL

LOCAL_PORT=6443
KCFG=$ROOT/kubeconfig

log "starting IAP tunnel to $K3S_SERVER_NAME:6443 -> 127.0.0.1:$LOCAL_PORT"
gcloud compute start-iap-tunnel "$K3S_SERVER_NAME" 6443 \
  --local-host-port="127.0.0.1:$LOCAL_PORT" \
  --zone="$K3S_SERVER_ZONE" >/tmp/iap.log 2>&1 &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > /tmp/iap.pid

# Wait for the tunnel to bind.
wait_until "IAP tunnel bound" 30 1 \
  bash -c "exec 3<>/dev/tcp/127.0.0.1/$LOCAL_PORT && exec 3<&- && exec 3>&- 2>/dev/null" \
  || { cat /tmp/iap.log; fail "IAP tunnel never came up"; }

log "minting OIDC ID token for $K8S_DEPLOYER_SA_EMAIL"
# --include-email is required: kube-apiserver is configured with
# oidc-username-claim=email, and Google's impersonation flow omits the
# email claim from the ID token unless this flag is set.
ID_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="$K8S_DEPLOYER_SA_EMAIL" \
  --audiences="$K8S_DEPLOYER_SA_EMAIL" \
  --include-email)

log "writing kubeconfig -> $KCFG"
# We skip TLS verification because the k3s server cert SAN doesn't include
# 127.0.0.1 by default. Auth still goes through OIDC; TLS is only for the
# transport between the runner and the IAP-tunneled localhost endpoint.
cat > "$KCFG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: https://127.0.0.1:$LOCAL_PORT
      insecure-skip-tls-verify: true
users:
  - name: ci
    user:
      token: $ID_TOKEN
contexts:
  - name: k3s
    context:
      cluster: k3s
      user: ci
current-context: k3s
EOF
chmod 0600 "$KCFG"

export KUBECONFIG=$KCFG
log "kubectl ready"
kubectl version --short 2>/dev/null || kubectl version
