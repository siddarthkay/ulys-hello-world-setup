# ulys-hello-world-setup (k3s edition)

A 3-service hello-world (`web` -> `api` -> `worker` + Postgres + Redis) running on a self-hosted k3s cluster on GCP. Provisioned by Terraform, shipped via GitHub Actions, with an Argo Rollouts canary gated on a webMetric (`/readyz` against the canary Service) and a Prometheus query against kube-state-metrics. The control plane and one worker run on TF-provisioned GCE VMs; everything above the kernel is a k8s object.

```
$ make loc
  file                      lines
  ------------------------- -----
  app/api/app.py               79
  app/worker/app.py            26
  app/web/index.html           41
  ------------------------- -----
  total                       146 / 200
```

---

## Philosophy: cloud-agnostic, max-control

The orchestration layer is k3s, not GKE. Lift-and-shift to Hetzner / EC2 / a closet box is the same TF tfvars change as before — k3s has no GCP-specific dependency. What stayed managed-GCP and why:

| Component | Could self-host? | Why I didn't |
|---|---|---|
| GCS state bucket | Yes | State surviving a "node blew up" event is the whole point of remote state. |
| Artifact Registry | Yes | Free tier covers this scale; chicken-and-egg if the registry runs in the cluster. |
| Secret Manager | Yes | IAM revocation is instant; no encrypted-at-rest secret material in git history. |
| WIF, IAP, billing budget | No equivalent | Per-cloud or required by the rubric. |

Self-hosted on top of GCP IaaS:

| Layer | Choice |
|---|---|
| Orchestrator | **k3s v1.30.x+k3s1** (Traefik disabled, servicelb on) |
| Ingress + TLS | **Caddy Ingress Controller** with Caddy's built-in automatic-HTTPS (Let's Encrypt directly — no cert-manager). |
| Canary | **Argo Rollouts**, replica-based (50/100). pause + analysis (webMetric `/readyz` + Prometheus pod-readiness ratio). No traffic-shifting (no plugin exists for Caddy Ingress; ingress-nginx has the option if you want it later). |
| Secrets sync | **External Secrets Operator** -> GCP Secret Manager via Application Default Credentials (the node SA's metadata-server token; no WIF, no JSON key). |
| Metrics | **kube-prometheus-stack** (Prometheus + kube-state-metrics; Grafana + Alertmanager disabled to fit on e2-medium). |
| Image-pull auth | In-cluster `CronJob` refreshes a `kubernetes.io/dockerconfigjson` Secret every 30 min using the agent SA's metadata token; pods reference it via `imagePullSecrets`. (k3s registries.yaml is broken in containerd `config_path` mode — see `deploy/base/ar-creds.yaml` comment.) |
| TLS hostname | sslip.io derived from the agent's static IP. |

## Architecture

```
                                      https://<ip>.sslip.io
                                                │
                                                ▼
            ┌───────────────────────────── k3s cluster ─────────────────────────────┐
            │                                                                       │
            │   ┌─── server (e2-medium) ─────────┐    ┌─── agent (e2-medium) ────┐  │
            │   │                                │    │                          │  │
            │   │  kube-apiserver (OIDC)         │    │  caddy-ingress (80/443)  │  │
            │   │  cert-manager                  │    │  ▲                       │  │
            │   │  external-secrets-operator     │    │  │ /api -> api-stable    │  │
            │   │  argo-rollouts                 │    │  │       (canary mutates │  │
            │   │  kube-prometheus-stack         │    │  │        weights)       │  │
            │   │                                │    │  │ /     -> web         │  │
            │   └────────────────────────────────┘    │  │                       │  │
            │                                         │  ▼                       │  │
            │                                         │ api (Rollout, 2 pods)    │  │
            │                                         │   │                      │  │
            │                                         │   ▼                      │  │
            │                                         │ worker (Rollout, 2 pods) │  │
            │                                         │   │                      │  │
            │                                         │   ▼                      │  │
            │                                         │ postgres (StatefulSet)   │  │
            │                                         │   PV: hostPath /mnt/pg   │  │
            │                                         │       (GCE PD attached)  │  │
            │                                         │ redis (Deployment)       │  │
            │                                         └──────────────────────────┘  │
            └───────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
                                  google_compute_disk "pgdata"
                                  (10 GB, pd-balanced, attached to agent)
```

## Local equals CI

```bash
make preflight    # validate local tools
make test         # pytest api + worker
make tf-plan      # plan against the cluster TF root
make ci-pr        # everything the PR workflow does
make ci-deploy    # everything the main workflow does after `make test`
```

`make help` lists the full set.

---

## Setup (fresh GCP project)

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gh auth login
```

```bash
make all-bootstrap
git push -u origin main
```

Workflow steps on push:

1. `pytest` against api and worker.
2. WIF auth to GCP.
3. `terraform apply` (no-op if you applied locally first). Provisions VPC, two GCE VMs, IAM, AR, etc.
4. Build + push three images (api, worker, web), SHA-tagged.
5. Open IAP TCP tunnel to the k3s server's 6443.
6. Mint a Google-issued OIDC ID token by impersonating `k8s-deployer-sa` (with `--include-email` so the `email` claim is present, since kube-apiserver is configured with `oidc-username-claim=email`). kube-apiserver verifies the token via `oidc-issuer-url=https://accounts.google.com`.
7. `kustomize edit set image` on the overlay; `kubectl delete job ar-cred-refresher-init` (Job PodSpec is immutable; delete-before-apply lets each deploy mint a fresh AR token); `kubectl apply -k`; `kubectl wait` for the cred-refresher Job; `kubectl argo rollouts status` for the api + worker Rollouts.
8. Smoke check `https://<domain>/api/version`.

After it succeeds:

```bash
cd terraform/main
terraform output web_url
curl https://$(terraform output -raw domain)/api/version
curl https://$(terraform output -raw domain)/api/work
```

---

## Service-to-service auth

| Edge | Mechanism |
|---|---|
| Internet -> ingress | TLS via Caddy's built-in automatic-HTTPS (Let's Encrypt). No cert-manager. |
| Ingress -> api | Path-prefix routing in the Ingress (`/api` -> api-stable, `/` -> web). Replica-based canary; the canary pod doesn't receive ingress traffic, only direct probes from the analysis. |
| api -> worker | HMAC-SHA256 signed body. NetworkPolicy also blocks worker ingress to api pods only (defense in depth). |
| api -> postgres / redis | NetworkPolicy: only api pods can reach postgres:5432, redis:6379. Postgres password from ExternalSecret -> SM. |
| Pod -> Artifact Registry | `imagePullSecrets: ar-creds` references a `dockerconfigjson` Secret refreshed every 30 min by an in-cluster CronJob; the CronJob fetches an OAuth token from the agent node's metadata server. |
| GHA -> GCP | Workload Identity Federation. `attribute_condition = assertion.repository == '<owner>/<repo>'`. |
| GHA -> k3s API | IAP TCP tunnel + Google-issued OIDC ID token (no static kubeconfig at rest). |
| ESO -> Secret Manager | Application Default Credentials = the node SA's metadata-server token. ESO pod runs on the agent (which has `secretmanager.secretAccessor`); ADC picks the token transparently. No projected SA tokens, no WIF dance. |

---

## Architecture decisions and tradeoffs

| Decision | Why |
|---|---|
| **k3s, not GKE** | "Self-hosted" is the whole point. k3s is single-binary, no managed-control-plane fee, portable. GKE would obviate half the IAM and OIDC plumbing here at the cost of welding the orchestrator to GCP. |
| **Postgres in-cluster on a hostPath PV** | Same data-path ownership as the previous VM-only shape: PD is TF-managed, mounted on the agent at `/mnt/pgdata`, pinned to the agent via nodeAffinity. Survives node rebuilds because the PD is a separate resource with its own lifecycle. Avoids needing a CSI driver for a single-node PV. |
| **No StorageClass / dynamic provisioning** | Single PV, single PVC, manually provisioned. Fewer moving parts. Add the GCE PD CSI driver if multi-node dynamic PVCs become a thing. |
| **Caddy Ingress Controller, not nginx-ingress** | Closest port of the previous Caddy-on-VM shape. Caddy's built-in automatic-HTTPS issues Let's Encrypt certs without cert-manager, which sidesteps the HTTP-01 self-check / HTTP→HTTPS redirect chicken-and-egg. Tradeoff: there's no Argo Rollouts traffic-router plugin for Caddy Ingress (verified — `argoproj-labs/rollouts-plugin-trafficrouter-caddy` doesn't exist), so canary is replica-based instead of weighted-ingress. The pause + analysis still gate promotion. |
| **No cert-manager** | Caddy Ingress's automatic-HTTPS is the same Let's Encrypt path cert-manager would have driven, minus the self-check that fights Caddy's redirect. Less moving parts. |
| **Replica-based canary (no traffic shifting)** | The Argo Rollouts canary step at `setWeight: 50` creates 1 canary pod (out of 2) without sending ingress traffic to it. The `webMetric` analysis probes the canary directly via the canary Service. This validates app-level health (DB + Redis + worker chain) but not "canary handles real traffic safely" — the latter would need a service mesh or ingress-nginx canary annotations. |
| **AnalysisTemplate**: webMetric + Prometheus | Two metrics gating each canary step. `webMetric` does an HTTP `/readyz` against `api-canary.app:8080` (FQDN required since Argo Rollouts runs in another namespace). The `prometheus` metric queries kube-state-metrics for the ratio of Ready api pods. Caddy doesn't expose `/metrics` by default in its chart, so request-level signal isn't available — kube-state-metrics gives pod-level readiness, which is the next-best thing. |
| **External Secrets Operator using ADC, not WIF** | ESO pod runs on the agent node, which has `secretmanager.secretAccessor` on both secrets. Google's SDK picks up the metadata-server token automatically. WIF would have been more granular ("ESO's k8s SA, not the whole node, can read SM") but requires a working cluster OIDC issuer URL that GCP STS can fetch — extra moving parts (public OIDC bucket, JWKS publishing) for a single-node-cluster value. Easy to revisit if the cluster grows. |
| **AR pull via in-cluster CronJob writing dockerconfigjson** | k3s's native `registries.yaml` doesn't propagate auth to containerd's per-host config in `config_path` mode (k3s-io/k3s#12736), so app pods 401'd. The canonical k8s pattern — `kubernetes.io/dockerconfigjson` Secret + `imagePullSecrets` — works regardless of containerd version. A CronJob in the `app` namespace refreshes the Secret every 30 min using the agent SA's metadata token; an init Job runs on first deploy so we don't wait for the cron tick. |
| **OIDC ID-token kubeconfig, not a long-lived static kubeconfig in GCS** | GHA impersonates `k8s-deployer-sa` via WIF, mints a 1-hour Google ID token (with `--include-email` so the email claim that kube-apiserver checks is present), kube-apiserver verifies via `oidc-issuer-url=https://accounts.google.com`. No secret material at rest. RBAC is a single ClusterRoleBinding scoped to the deployer email. |
| **kube-apiserver on private 6443 only, IAP-tunneled** | Same trust model as the old IAP SSH for the VM. The k8s API is never reachable from the public internet. |
| **Two e2-medium nodes** | Server runs k3s control plane + ESO + Argo Rollouts + kube-prometheus-stack (~3 GB). Agent runs Caddy ingress + postgres + redis + 2x api + 2x worker + web (~2 GB). e2-small is too tight on either; e2-medium has 4 GB and headroom. |

---

## Estimated monthly cost (us-central1, 24/7)

| Item | $/mo |
|---|---|
| 2x `e2-medium` VM (Ubuntu 22.04) | ~49.00 |
| 2x 20 GB pd-standard boot | ~1.60 |
| 10 GB pd-balanced data disk (pgdata) | ~1.00 |
| Static external IP (in use, attached) | 0.00 |
| Artifact Registry (1 repo, <1 GB) | <0.10 |
| Secret Manager (2 secrets) | <0.10 |
| GCS state + cluster-state + oidc buckets | <0.10 |
| Logging + egress | <1.00 |
| **Total** | **~$53/mo** |

Higher than the single-VM shape (~$16) because we're running an actual cluster with monitoring. The control plane is the largest line-item; HA (3 server nodes) would push this to ~$120.

---

## Operating notes

### Postgres password rotation

Update the secret in SM. ESO refreshes the `db-password` k8s Secret within 5m. Apply the rotation to the running Postgres:

```bash
kubectl exec -n app statefulset/postgres -- \
  psql -U app -d app -c "ALTER USER app WITH PASSWORD '<new>'"
kubectl rollout restart -n app deploy/api  # picks up the new env value
```

### k3s version upgrades

Bump `var.k3s_version`. `terraform apply` re-renders cloud-init but does not re-execute on existing nodes — drain + reboot the agent first, then the server. For minor upgrades, `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=... sh -` on each node is also fine.

### Postgres / Redis version upgrades

Same as before: pinned to `postgres:16-alpine` / `redis:7-alpine` in `deploy/base/`. Postgres major-version upgrades require `pg_upgrade` or dump+restore.

### Drain a node

```bash
kubectl drain ulys-k3s-agent --ignore-daemonsets --delete-emptydir-data
# do work
kubectl uncordon ulys-k3s-agent
```

---

## What I'd add for production

- **HA control plane:** 3-server k3s with embedded etcd + a regional internal LB in front of the API server.
- **Postgres backups:** CronJob running `pg_dump | gcloud storage cp` to a versioned bucket; periodic restore drills.
- **CSI-backed StatefulSets:** swap the hostPath PV for the GCE PD CSI driver so postgres can move between nodes.
- **Argo CD:** replace `kubectl apply -k` from CI with a pull-based sync. Drift detection comes for free.
- **Pod Security Admission + image signature verification (cosign / sigstore policy-controller).**
- **kube-prometheus-stack alerting + Grafana** (currently stripped to Prom-only to fit on e2-medium).
- **NetworkPolicy default-deny-all** in `app` ns; the current rules are allow-only on top of an implicit allow-all.
- **VPC Service Controls** on Secret Manager + Artifact Registry.
- **Per-environment WIF + project isolation** (the README's old "staging vs prod" section still applies — replace `terraform/main` with `terraform/modules/cluster` + per-env roots).
