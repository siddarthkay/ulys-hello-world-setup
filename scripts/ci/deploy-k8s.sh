#!/usr/bin/env bash
# Apply the kustomize overlay, set image tags, kick off the canary, and
# wait for Argo Rollouts to fully promote (or auto-abort).
#
# Required env:
#   IMAGE_REGISTRY    e.g. us-central1-docker.pkg.dev/PROJECT/ulys-images
#   IMAGE_TAG         short SHA
#   DOMAIN            sslip.io hostname for the ingress
#   KUBECONFIG        set by k8s-auth.sh; if unset we expect ./kubeconfig
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
need_env IMAGE_REGISTRY
need_env IMAGE_TAG
need_env DOMAIN
export KUBECONFIG=${KUBECONFIG:-$ROOT/kubeconfig}

OVERLAY=$ROOT/deploy/overlays/single-env

log "patching image refs in overlay"
( cd "$OVERLAY" && \
  kustomize edit set image \
    "ulys/api=$IMAGE_REGISTRY/api:$IMAGE_TAG" \
    "ulys/worker=$IMAGE_REGISTRY/worker:$IMAGE_TAG" \
    "ulys/web=$IMAGE_REGISTRY/web:$IMAGE_TAG" )

REGISTRY_HOST=${IMAGE_REGISTRY%%/*}

log "rendering with DOMAIN=$DOMAIN, REGISTRY_HOST=$REGISTRY_HOST and applying"
# The ar-cred-refresher-init Job's PodSpec is immutable; a re-apply with
# any spec change errors out. Delete it first so a fresh Job runs each
# deploy and produces a fresh ar-creds Secret.
kubectl delete job -n app ar-cred-refresher-init --ignore-not-found --wait=false || true

kubectl kustomize "$OVERLAY" \
  | sed -e "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" \
        -e "s|REGISTRY_HOST_PLACEHOLDER|$REGISTRY_HOST|g" \
  | kubectl apply -f -

# Block on the AR-cred-refresher init Job: app rollouts pull from AR via
# the ar-creds Secret it produces, so wait for the Secret to exist before
# rollout. CronJob keeps it fresh after that.
log "waiting for ar-cred-refresher-init Job to complete"
kubectl wait --for=condition=complete -n app job/ar-cred-refresher-init --timeout=2m

log "waiting for api rollout to fully promote"
kubectl argo rollouts -n app status api --timeout 10m

log "waiting for worker rollout to fully promote"
kubectl argo rollouts -n app status worker --timeout 5m

log "rollouts complete"
