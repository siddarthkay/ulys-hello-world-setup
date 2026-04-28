# ulys-hello-world-setup

A 3-service hello-world (`web` → `api` → `worker` + Postgres + Redis) on GCP, built with the **A+ pick from the audit applied to every component**: Cloud Run for compute, Cloud SQL HA + PITR for Postgres, Memorystore Standard for Redis, GCS + Cloud CDN behind an HTTPS Load Balancer for the static site, and Cloud Run revision-based traffic-split canary for deploys.

```
$ make loc
  file                      lines
  ------------------------- -----
  app/api/app.py              101
  app/worker/app.py            38
  app/web/index.html           41
  ------------------------- -----
  total                       180 / 200
```

## Architecture

```
                         https://<lb-ip>.sslip.io
                                    │
                          ┌─────────┴──────────┐
                          │  HTTPS LB (global) │
                          │  ├─ /        → GCS │   (Cloud CDN)
                          │  └─ /api/*   → api │
                          └────┬────────┬──────┘
                               │        │
                               │        ▼
                               │   ┌────────────────────┐
                               │   │ Cloud Run: api     │  ingress=ALL
                               │   │ revisions w/ tags  │  scale-to-zero
                               │   │ traffic split via  │  VPC connector → private
                               │   │ gcloud run         │  IPs only
                               │   └────┬────┬──────────┘
                               │        │    │ ID token (aud=worker URL)
                               │        │    ▼
                               │        │ ┌──────────────────────┐
                               │        │ │ Cloud Run: worker    │ ingress=internal-only
                               │        │ │ no-allow-unauth      │ roles/run.invoker
                               │        │ │ verify ID token      │ on api SA only
                               │        │ └──────────────────────┘
                               │        │
                               │        │ Serverless VPC Connector
                               │        ▼
                               │ ┌──────────────────────────────┐
                               │ │  custom VPC                  │
                               │ │  ├─ Cloud SQL Postgres       │ private IP
                               │ │  │  REGIONAL HA, PITR,       │ availability_type
                               │ │  │  7-day backups            │ = REGIONAL
                               │ │  └─ Memorystore Redis        │ private IP
                               │ │     STANDARD_HA (replica)    │
                               │ └──────────────────────────────┘
                               │
                               ▼
                       ┌───────────────────┐
                       │  GCS bucket: web  │ static site (index.html)
                       │  + Cloud CDN      │ global edge cache
                       └───────────────────┘
```

## Service-to-service auth

| Edge | Mechanism |
|---|---|
| user → web | HTTPS LB → GCS backend bucket, Cloud CDN cached |
| user → api | HTTPS LB URL-map `/api/*` → Serverless NEG → Cloud Run api |
| api → worker | Google ID token, `aud` = worker URL, signed by api SA, verified by worker against api SA email |
| api → DB | psycopg2 over Serverless VPC Connector → Cloud SQL private IP |
| api → Redis | redis-py over the same VPC Connector → Memorystore private IP |
| GHA → GCP | Workload Identity Federation, repo-locked via `attribute_condition` |

worker has `ingress=internal-only` AND `--no-allow-unauthenticated` AND only the api SA has `roles/run.invoker`. Three layers of defense: network isolation + IAM + caller-identity check on the token's `email` claim.

## Cost

| Item | $/mo |
|---|---|
| Cloud SQL Postgres `db-custom-1-3840`, REGIONAL, PITR, 10 GB SSD | ~70 |
| Memorystore Redis Standard 1 GB (HA replica) | ~70 |
| Serverless VPC Connector (2× e2-micro min) | ~10 |
| HTTPS LB (forwarding rule + URL map) | ~18 |
| Cloud Run (3 services, scale-to-zero, hello-world traffic) | <1 |
| Cloud CDN (low traffic) | <1 |
| GCS web bucket | <0.10 |
| Artifact Registry | <0.10 |
| Secret Manager | <0.10 |
| Logging | <2 |
| **Total** | **~$170/mo** |

## Useful Links

- successful deploy: https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25220204859
- failure run: https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25220309370
- fixed run:https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25220471316
- terraform destroy output : [`docs/destroy.txt`](docs/destroy.txt)
---

## The canary

Cloud Run native traffic-splitting, no Caddy, no flock, no GCS active.color file:

```
1. gcloud run deploy api --image=...:$SHA --no-traffic --tag=cand-$SHA --revision-suffix=$SHA
2. probe https://cand-$SHA---api-...run.app/readyz   ← direct tag URL, no public traffic
3. gcloud run services update-traffic --to-revisions=$NEW=10,$LAST_GOOD=90
4. probe https://<lb-domain>/api/readyz × 50, ≤2 failures allowed
5. update-traffic --to-revisions=$NEW=50,$LAST_GOOD=50; probe
6. update-traffic --to-revisions=$NEW=100; probe with 0 failures allowed
7. on any failure: update-traffic --to-revisions=$LAST_GOOD=100  (rollback)
```

The forcing function is preserved: a broken `/readyz` fails step 2, never gets traffic, rollback is implicit (no traffic was ever given to the broken revision). Public users see the previous good revision throughout.

## Setup

Required: a GCP project with billing enabled, an empty (or new) GitHub repo, and these CLIs installed and authenticated:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gh auth login
```

Then, from the repo root:

```bash
make all-bootstrap
```

The orchestrator prompts for project, repo, billing account, alert email, and region (defaults pulled from local config). It then:

1. Validates `gcloud`, `terraform`, `gh`, `openssl`, `jq` are installed and authenticated.
2. Sets the ADC quota project (`billingbudgets` requires it).
3. Writes `terraform/bootstrap/terraform.tfvars`.
4. `terraform apply` on bootstrap (state bucket, WIF, GHA SA, $20 budget).
5. Creates the DB password secret in Secret Manager.
6. Pushes 5 GitHub Actions secrets (`GCP_PROJECT_ID`, `GCP_TF_STATE_BUCKET`, `GCP_WIF_PROVIDER`, `GCP_GHA_SA_EMAIL`, `GCP_REGION`).
7. Writes `terraform/main/terraform.tfvars`.
8. `terraform apply` on main (VPC, PSA, VPC Connector, Cloud SQL HA, Memorystore Standard, Cloud Run skeleton, HTTPS LB, GCS+CDN, AR). **~12-15 minutes**, mostly Cloud SQL HA provisioning.
9. Rotates the Cloud SQL `app` user password to the SM-stored value.

After bootstrap finishes, push to trigger the first CI deploy:

```bash
git push -u origin main
```

CI:

1. Tests (api + worker pytest).
2. WIF auth.
3. `terraform apply` (no-op if you applied locally).
4. Build + push 2 images (api, worker) to Artifact Registry.
5. `gsutil rsync` `app/web/` to the static-site bucket; CDN invalidate.
6. Cloud Run canary: deploy api candidate `--no-traffic --tag=cand-$SHA`, probe direct tag URL, traffic-split 10/50/100 with rollback on probe failure.

## TLS caveat 

The HTTPS LB uses a **Google-managed SSL cert** for `<lb-ip>.sslip.io`. First issuance happens via Load-Balancer-Authorization, which requires the LB to actually serve traffic on that domain before the cert can validate. **Provisioning takes 15-30 minutes** the first time; until then, HTTPS responses return cert errors.

Watch progress:

```bash
gcloud compute ssl-certificates describe ulys-cert --global \
  --format='value(managed.status,managed.domainStatus)'
# PROVISIONING -> ACTIVE
```

Once the cert is `ACTIVE`, the LB serves valid HTTPS. Until then, **the canary's public-traffic probes will fail** because curl rejects the cert. Workaround: skip the public probes in CI for the very first deploy (or `curl -k` to bypass cert validation), or wait 30 minutes after `make all-bootstrap` before pushing to main.

## Architecture decisions

| Decision | Why |
|---|---|
| **Cloud Run + traffic split** instead of MIG/GKE/Cloud Run with manual rollout | Native `--traffic` revision tags collapse "deploy + canary + rollback" into one primitive.  |
| **Cloud SQL `db-custom-1-3840` + REGIONAL HA + PITR** instead of `db-f1-micro` zonal | Synchronous standby zone + 7-day backup retention + point-in-time recovery. ~7× the cost of the smallest zonal tier; right answer when the data matters. |
| **Memorystore Redis Standard** instead of Basic | Replica with automatic failover. Doubles the cost; correct for "serving real traffic." |
| **HTTPS LB + GCS + Cloud CDN** instead of Cloud Run serving static | Static content gets edge-cached at CDN PoPs. Same-origin via URL map (`/` → bucket, `/api/*` → Cloud Run NEG).  |
| **ID tokens** for api → worker instead of HMAC | Native GCP IAM; `roles/run.invoker` is the policy. Worker verifies `aud` claim equals its URL and `email` claim equals the api SA.  |
| **`ingress=internal-only` on worker** | Worker's `*.run.app` URL is unreachable from the public internet; only callers traversing the VPC connector or VPC peering can reach it. The api uses the connector for DB+Redis traffic, separately from how it reaches worker (default Cloud Run egress + IAM). |
| **Serverless VPC Connector**, not direct IP allowlisting | Required for Cloud Run to reach Cloud SQL/Memorystore on private IPs. PRIVATE_RANGES_ONLY egress mode means public-internet traffic uses default Cloud Run egress (faster, cheaper). |
| **Secret Manager** for DB password (not a TF `random_password`) | Values aren't in `terraform.tfstate`. Cloud Run mounts the secret via `secret_key_ref` directly, no env-var indirection. |
| **Bootstrap module separate from main** | The thing CI authenticates with (WIF + GHA SA) is created by bootstrap, so bootstrap can't run via CI. Two TF roots is intentional. |

## Adding a second environment (staging/prod)

 GitHub Environments gating WIF, image SHA promotion). The Cloud Run + LB + Cloud SQL HA model makes per-env isolation cleaner — Cloud Run revisions are per-service-per-project, not shared with anything else, so the only cross-env coupling is the shared Artifact Registry (in a "shared" project, optional).

## What I'd add for production beyond this

- **Image signing + verification** (cosign at build time, Binary Authorization at deploy time on Cloud Run).
- **VPC Service Controls** perimeter around Secret Manager + Artifact Registry + Cloud SQL.
- **Cloud Armor** in front of the LB (rate limiting, WAF rules, geo blocks).
- **Custom domain** (Cloud DNS managed zone) instead of sslip.io. Avoids the 15-30 min managed-cert wait.
- **Cloud SQL connector library** (`google-cloud-sql-connector` for psycopg2) instead of private-IP+password. IAM-based auth, automatic cert rotation.
- **Smarter canary**: SLO-based gates (latency p99, error rate from Cloud Monitoring) with a hold time at each stage, instead of `curl /readyz × 50`.
- **OpenTelemetry collector** sending traces and metrics to Cloud Operations.
- **Database migrations** with alembic / sqitch / golang-migrate. `CREATE TABLE IF NOT EXISTS` in the request path is fine for one table, awful for real apps.
- **Tightened GHA SA roles**: the bootstrap grants broad admin-tier roles to the deploy SA. Production should split plan-only vs apply, with apply gated on env approval.

## Repository layout

```
app/
  api/             Flask api + tests + Dockerfile
  worker/          Flask worker + tests + Dockerfile
  web/             index.html (uploaded to GCS by CI)
terraform/
  bootstrap/       state bucket, WIF, GHA SA, $20 budget
  main/            VPC + PSA + VPC connector, Cloud SQL HA, Memorystore Std,
                   Cloud Run api+worker, HTTPS LB, GCS+CDN, AR, SM data refs
.github/workflows/
  _test.yml        reusable: pytest api + worker
  pr.yml           tests + tf fmt/validate/plan; comments plan on PR
  main.yml         tests, tf apply, build images, upload web, Cloud Run canary
scripts/
  preflight.sh        local sanity check
  all-bootstrap.sh    fresh project to fully provisioned, idempotent
  destroy.sh          ordered teardown; tees output to docs/destroy.txt
  ci/                 one focused script per CI step
Makefile             dispatch layer; workflows call `make <target>`
```

## Tear-down

```bash
make destroy
```

Empties the web bucket first, then `terraform destroy` on main, then bootstrap, then sweeps the state bucket's versioned objects. 
