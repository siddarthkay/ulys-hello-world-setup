# ulys-devops-take-home

A 3-service hello-world (`web` → `api` → `worker` + Cloud SQL Postgres + Memorystore Redis) on GCP, fully provisioned by Terraform, shipped via GitHub Actions, with a real percentage-shifting canary and automatic rollback.

> **Submission links** (filled in after the run):
> - Successful deploy run: _TBD_
> - Failed-canary rollback run: _TBD_
> - `terraform destroy` output: `docs/destroy.txt`
> - Billing screenshot: _attached separately to email_

---

## Architecture

```
                                 https://<vm-ip>.sslip.io
                                            │
                          ┌─────────────────┼──────────────┐
                          │              VM (e2-micro)     │
                          │                 │              │
   user ────HTTPS────────▶│   ┌───────┐  ┌──▼─────────┐    │
                          │   │ Caddy │──┤ /          │    │
                          │   │ :443  │  │ file_server│    │
                          │   │       │  │ /opt/app/  │    │
                          │   │       │  │  web/      │    │
                          │   │       │  └────────────┘    │
                          │   │       │                    │
                          │   │       │  /api/* ──┐        │
                          │   │       │  rev_proxy│        │
                          │   │       │  weighted │        │
                          │   └──┬────┘           │        │
                          │      │                │        │
                          │      ▼                ▼        │
                          │  ┌─────────┐    ┌─────────┐    │
                          │  │api-blue │    │api-green│    │
                          │  │(active) │    │(canary) │    │
                          │  └────┬────┘    └────┬────┘    │
                          │       │              │         │
                          │  ┌────▼─────┐  ┌─────▼───┐     │
                          │  │worker-   │  │worker-  │     │
                          │  │blue      │  │green    │     │
                          │  │(HMAC)    │  │(HMAC)   │     │
                          │  └──────────┘  └─────────┘     │
                          └────────────────┬───────────────┘
                                           │ private VPC peering
                       ┌───────────────────┼───────────────────┐
                       ▼                                       ▼
               ┌──────────────┐                       ┌──────────────┐
               │ Cloud SQL    │                       │ Memorystore  │
               │ Postgres     │                       │ Redis        │
               │ (private IP) │                       │ (private IP) │
               └──────────────┘                       └──────────────┘
```

- **Public ingress:** only ports 80 + 443 are open to `0.0.0.0/0`. Caddy terminates HTTPS, redirecting :80 → :443. SSH is reachable only via IAP from the GH Actions SA — no public 22.
- **TLS:** Caddy auto-provisions a Let's Encrypt cert for the domain `<vm-ip>.sslip.io`. sslip.io is a free wildcard DNS service that resolves any IP-shaped subdomain back to the IP, which is enough for ACME to validate. Cost: $0. No domain registration needed.
- **`web` → `api`:** same origin (`/api/*`), no CORS dance, no mixed content.
- **`api` → `worker`:** HMAC-SHA256 over a shared secret. Worker rejects any request without a matching `X-Signature`. Worker is **not** published on a host port — only reachable via the internal docker network.
- **Data stores:** managed services. Cloud SQL Postgres on private IP via VPC peering; Memorystore Redis on private IP via the same peering range. The VM is the only thing in the VPC that can talk to them.
- **Image registry:** Artifact Registry (regional Docker repo). VM SA has reader, GHA SA has writer. Images age out via Terraform-defined cleanup policies.
- **Secrets:** DB password and worker shared secret live in Secret Manager. Their values are **not** in Terraform state — TF only creates the secret containers; values are added by `scripts/bootstrap-finish.sh` via `gcloud secrets versions add`. The VM SA reads `latest` at first boot and at every container restart.

## Local = CI

The CI workflows are intentionally thin wrappers around `make` targets — every CI step has a corresponding `make` target you can run on your laptop with the same env vars CI uses. `make help` lists them. Examples:

```bash
make preflight              # validate local tools, print bootstrap tfvars
make test                   # run pytest the same way CI does
make tf-plan                # uses the GCS backend; needs WIF auth or local gcloud creds
make ci-pr                  # everything the PR workflow does, end to end
make ci-deploy              # everything the main workflow does after `make test`
```

This means you can debug a failing CI run by reproducing it locally one step at a time.

## Repository layout

```
app/
  api/      Flask + Dockerfile + pytest    (~80 LOC of Python)
  worker/   Flask + Dockerfile + pytest    (~25 LOC of Python)
  web/      index.html (same-origin /api)  (~45 LOC)
deploy/
  compose.infra.yml   Caddy (long-lived)
  compose.app.yml     api + worker, parameterised by COLOR + image tag
  caddy/Caddyfile.tmpl  template the deploy script renders
  deploy.sh           canary orchestrator (10/50/100 weighted shifts)
terraform/
  bootstrap/  one-shot, run locally: state bucket, APIs, WIF, GHA SA, $20 budget
  main/       VPC + PSA, VM, Cloud SQL, Memorystore, Artifact Registry, Secret Manager
.github/workflows/
  pr.yml      tests + tf fmt/validate/plan; comments plan
  main.yml    tests → build → push to AR → tf apply → canary deploy → promote/rollback
scripts/
  preflight.sh         validates local env + prints values for tfvars
  bootstrap-finish.sh  emits main tfvars; populates Secret Manager + SQL pwd
  destroy.sh           ordered teardown; tees output to docs/destroy.txt
  ci/                  one focused script per CI step (test, tf-*, build-push,
                       wait-vm, scp-deploy, run-canary, smoke-public, ...)
Makefile             dispatch layer; workflows call `make <target>`
```

---

## Setup (fresh GCP project)

You need: a GCP project with billing enabled, `gcloud` CLI logged in, `terraform` ≥ 1.6, `jq`, an empty GitHub repo.

### 1. Preflight

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
./scripts/preflight.sh
```

Preflight prints the exact values to paste into the next step's tfvars.

### 2. Bootstrap (run once, locally)

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Paste values printed by preflight; fill in github_repo and budget_alert_email.
terraform init
terraform apply
```

Bootstrap needs your personal credentials because it creates the **billing budget** (which requires `billing.user` on the billing account — too sensitive to delegate to CI) and the **WIF binding** (chicken-and-egg: CI can't authenticate until WIF exists).

### 3. Emit main tfvars + register GitHub secrets

```bash
cd ../..
./scripts/bootstrap-finish.sh
```

This writes `terraform/main/terraform.tfvars` for you and prints the four GitHub Actions secrets to add (Settings → Secrets and variables → Actions):

| Secret | Source |
|---|---|
| `GCP_PROJECT_ID` | your project ID |
| `GCP_TF_STATE_BUCKET` | bootstrap output |
| `GCP_WIF_PROVIDER` | bootstrap output |
| `GCP_GHA_SA_EMAIL` | bootstrap output |

### 4. First `terraform apply` for main, then populate secrets

The first `terraform apply` of main can run via CI (push to `main`) or locally:

```bash
cd terraform/main
terraform init -backend-config="bucket=$(cd ../bootstrap && terraform output -raw state_bucket)"
terraform apply
```

Then re-run `bootstrap-finish.sh` so it can:
- generate a strong DB password (locally; never echoed)
- write it to Secret Manager
- set the password on the Cloud SQL `app` user
- generate the worker shared secret and store it in Secret Manager too

```bash
cd ..
./scripts/bootstrap-finish.sh
```

This is a one-time step. After this, secret rotation is just re-running the same script.

### 5. Trigger first deploy

Push to `main`. The workflow will:

1. Run pytest against api + worker.
2. Auth to GCP via WIF.
3. `terraform apply` (no-op if you already applied locally).
4. Build api + worker images, push to Artifact Registry tagged with the SHA.
5. Wait for the VM's startup script + secrets to be ready.
6. SCP `deploy/` + `app/web/` to the VM.
7. Run `deploy.sh` on the VM, which orchestrates the canary stages below.
8. Curl `https://<domain>/api/version` from CI as a final public check.

After it succeeds:

```bash
cd terraform/main
terraform output web_url           # https://<vm-ip>.sslip.io
terraform output api_base_url      # https://<vm-ip>.sslip.io/api
curl https://$(terraform output -raw domain)/api/version
curl https://$(terraform output -raw domain)/api/work
```

Open the web URL in a browser; the four buttons hit `/api/healthz`, `/api/readyz`, `/api/version`, `/api/work` and render the responses.

---

## The canary — what actually happens on every deploy

`deploy.sh` runs on the VM. State file `/opt/app/state/active.color` records which color (blue/green) is currently serving 100% of traffic.

| Stage | Caddy upstreams | What's checked |
|---|---|---|
| 0. bring up canary | unchanged (active=100%) | direct `/healthz`, `/readyz`, `/version`, `/work` against the new color over the docker network — confirms the new revision can talk to DB / Redis / worker before any public traffic touches it |
| 1. 90/10 split | `weighted_round_robin 90 10` | 50 sequential requests to public `https://domain/api/healthz`; ≤2 failures allowed |
| 2. 50/50 split | `weighted_round_robin 50 50` | same probe, ≤2 failures |
| 3. promote 100 | new color only | 50 requests to public, **0 failures allowed** |
| 4. tear down | — | old color's compose project is `down --remove-orphans` |

Any failure at any stage triggers `rollback`: revert Caddy to active-only, tear down the new color, exit 1. The previous revision stays serving the entire time — it's never drained until stage 4.

`docker reload` of Caddy is graceful (no dropped connections), so the weight transitions are seamless from the client's perspective.

## The forcing function — break `/readyz`, watch the rollback

After a green initial deploy:

1. **Break it.** Edit `app/api/app.py` to set the password lookup to a wrong value, or simpler — break the worker URL:
   ```python
   WORKER_URL = "http://worker-broken:9999"  # was os.environ["WORKER_URL"]
   ```
   Open PR, merge to main.
2. **Observe.** Pipeline runs:
   - tests still pass (worker URL is read at request time, not import time).
   - Image builds, pushes.
   - `terraform apply` no-op for infra.
   - `deploy.sh` brings up the canary; **stage 0's direct `/readyz` probe fails** because `requests.post` to `worker-broken:9999` errors out.
   - `rollback` trap fires. Old color keeps serving. Workflow exits non-zero.
   - The previous `/version` SHA is still what the public endpoint returns.
3. **Fix it.** Revert, push, watch the next run promote successfully.

## Service-to-service auth — what's enforced

- **`api` → `worker`:** every request includes `X-Signature: HMAC_SHA256(WORKER_SECRET, body)`. Worker recomputes and rejects on mismatch. `WORKER_SECRET` is in Secret Manager, written there by `bootstrap-finish.sh`.
- **Worker network isolation:** worker container has no host port. It's only on the internal docker `appnet` bridge. Even root on the VM can't reach it without first being in that network.
- **GitHub Actions → GCP:** Workload Identity Federation. The provider has `attribute_condition = "assertion.repository == '<owner>/<repo>'"` so only this repo's OIDC tokens can mint GCP creds. No JSON keys.
- **GHA → VM:** SSH only via IAP. Public 22/tcp is firewalled to the IAP CIDR; GHA SA has `roles/iap.tunnelResourceAccessor` + `roles/compute.osAdminLogin`.
- **VM → managed data:** private IPs only via VPC peering. Cloud SQL has `ipv4_enabled = false`; Memorystore is in `PRIVATE_SERVICE_ACCESS` mode. Neither has a public endpoint.

---

## Architecture decisions and tradeoffs

| Decision | Why |
|---|---|
| **Cloud SQL + Memorystore (managed)** rather than containers on the VM | Spec requires "data stores" provisioned by Terraform. Containers-on-the-VM was tempting (~$33/mo cheaper) but doesn't satisfy the spec literally. Going managed also unlocks PITR / failover later. |
| **Memorystore Basic 1 GB**, not Standard | Standard adds HA replication for ~2.5× the cost. Hello-world doesn't need it. |
| **Cloud SQL `db-f1-micro` zonal, no backups** | Cheapest viable Cloud SQL tier (~$9.50/mo). Backups + HA double the cost. README "prod gaps" calls this out. |
| **e2-micro VM with Caddy, not a Cloud Run service per app** | Cloud Run cost scales with requests; for steady-state hello-world it's wash, but Cloud Run + Cloud SQL Connector + serverless VPC connector adds three more failure modes for very little gain. Single VM is also where Caddy's automatic Let's Encrypt + sslip.io trick fits cleanly. |
| **sslip.io for TLS** instead of buying a domain | Free, real public DNS, valid for Let's Encrypt's HTTP-01 challenge. Tradeoff: not a brand domain; for prod, swap in a real one (Caddyfile change is one line). |
| **Caddy, not nginx** | Caddy auto-handles cert issuance + renewal + HTTPS redirect with no extra config. nginx + certbot would be three more moving parts. Caddy's reverse_proxy also has built-in `weighted_round_robin` which is what the canary uses. |
| **Real canary (10 → 50 → 100)** rather than blue/green smoke-then-flip | Spec says "deploy a canary." 10/50/100 actually splits production traffic. Each stage has its own probe budget. Earlier failures = less blast radius. |
| **Artifact Registry**, not ghcr.io | Spec requires "container registry" provisioned by TF. Artifact Registry is the GCP-native option. AR also lets the VM SA pull without a separate token — the SA's auth is enough. |
| **Secret Manager containers in TF, values added out-of-band** | "No secrets in state" requirement. If we used `random_password`, the value would land in `terraform.tfstate`. Instead TF creates the empty secret resource; `gcloud secrets versions add` writes the value. State only has the secret's resource name. |
| **VM persistent state on the boot disk only** | Cloud SQL holds all DB data, so we don't need a second disk like in v1. Less to clean up on destroy. |
| **Bootstrap module separate from main** | The very thing CI authenticates with (WIF + GHA SA) is created by bootstrap, so bootstrap can't run via CI. Budget creation also needs `billing.user` which is too dangerous to delegate. Two TF roots is correct here, not a workaround. |
| **No Ansible** for VM config | Considered it; rejected. Ansible needs SSH access, which itself depends on Terraform. Adds a layer without removing chicken-and-egg. The startup script is ~30 lines and runs once at first boot. Cleaner to keep it inline in TF. |

---

## Estimated monthly cost (us-central1, 24/7, no free-tier credit)

| Item | $/mo |
|---|---|
| Cloud SQL Postgres `db-f1-micro` zonal + 10 GB HDD | ~9.50 |
| Memorystore Redis Basic 1 GB | ~33.00 |
| `e2-micro` VM (Debian 12) | ~6.10 |
| 10 GB pd-standard boot disk | ~0.40 |
| Static external IP (in use) | 0.00 |
| Artifact Registry (1 repo, <1 GB) | <0.10 |
| Secret Manager (2 secrets) | <0.10 |
| GCS state bucket (versioned, tiny) | <0.05 |
| Logging + egress | <1.00 |
| **Total** | **~$50/mo** |

This is **above** the spec's stated $5–15 estimate — Memorystore's 1 GB minimum is the dominant cost. But the spec's $5–15 figure assumes you destroy the day you finish; my realistic same-day spend is **$1–3** (Cloud SQL + Memorystore prorate hourly). The $20 budget alert covers if it's left running ~half a month.

If a reviewer wanted to drive cost down to fit $5–15 strictly, the lever is "Memorystore → Redis-on-VM" — but that violates the "data stores in Terraform" requirement. I picked spec compliance.

---

## Adding a second environment (staging vs prod)

I would **not** copy-paste the modules. Approach:

1. Keep `terraform/main/*.tf` flat; introduce `var.environment` (`staging`/`prod`) and prefix every resource name with it.
2. Use **Terraform workspaces** for state isolation: `terraform workspace new staging` and `prod`. Each workspace gets `gs://...tfstate/main/<workspace>.tfstate`.
3. Per-env tfvars: `staging.tfvars`, `prod.tfvars`. CI passes `-var-file=$ENV.tfvars` and selects workspace via `TF_WORKSPACE`.
4. **Promotion gate:** the same image SHA flows staging → prod. The current `main.yml` builds once and tags by SHA; a `promote.yml` workflow (manual `workflow_dispatch` or on-tag) re-runs *only* the deploy step against prod, with the SHA as input. Never rebuilds — guarantees the artifact is identical.
5. GitHub Environments (`staging`, `prod`) with required reviewers on `prod`. WIF provider's `attribute_condition` extended to bind environment claims, so only an `environment: prod`-labeled run can mint prod GCP creds.
6. **Stronger isolation if budget allows:** separate GCP projects per env (separate billing, separate IAM blast radius, separate budgets). Cheaper but weaker: one project, separate VPCs + name prefixes.

Why workspaces over folders: single source of truth for infra graph, workspace name flows into resource names so a typo can't accidentally target prod from a staging plan.

---

## What I'd add for production (skipped here for time/cost)

- **HA compute:** managed instance group with a regional health-checked LB instead of one VM. Single VM is a SPOF; reboot = brief outage.
- **Cloud SQL HA + PITR:** `availability_type = REGIONAL` and 7-day backup retention. Currently zonal + no backups.
- **Memorystore Standard:** read replica + automatic failover.
- **Custom domain + Cloud DNS:** drop sslip.io for a real DNS zone; managed by TF.
- **VPC Service Controls:** lock Secret Manager + Artifact Registry behind a perimeter so a leaked SA token can't be abused from outside the org's networks.
- **Image scanning** (Trivy) and SBOM generation in CI; cosign signatures verified at deploy.
- **Smarter canary:** SLO-based gates (latency p99, error rate from real metrics, not just curl probes), and a hold time at each stage so you can catch slow-burn failures.
- **Database migrations** with a versioned tool (alembic / golang-migrate / sqitch). Currently `CREATE TABLE IF NOT EXISTS` runs in the request path — fine for one table, awful for real apps.
- **Observability stack:** OpenTelemetry collector → Cloud Operations or Grafana stack. Currently just stdout logs.
- **Tightened IAM:** the GHA SA has broad admin-tier roles in bootstrap. Production should split plan-only and apply roles, with apply gated on env approval.
- **Scheduled `terraform plan` drift detection** that opens a PR if the world doesn't match the code.
- **State bucket DR:** cross-region replica or a daily export to a separate project so a project-delete fat-finger doesn't lose everything.

---

## Tear-down

```bash
./scripts/destroy.sh         # main → bootstrap → state bucket sweep
# Output is teed to docs/destroy.txt for submission.

# Keep bootstrap in place for a re-deploy:
./scripts/destroy.sh --keep-bootstrap
```

The state bucket has versioned objects that `terraform destroy` won't remove on its own. The script does the final `gcloud storage rm -r` after bootstrap is gone, so you can re-run `bootstrap` later into the same project without "bucket already exists" or "bucket not empty" errors.
