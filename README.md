# ulys-hello-world-setup
 
A 3-service hello-world (`web` -> `api` -> `worker` + Postgres + Redis) on GCP. Provisioned by Terraform, shipped via GitHub Actions, with a percentage-shifting canary and automatic rollback. All four service tiers (web, api, worker, *and* the data stores) run as containers on a single TF-provisioned VM. The only managed GCP services in the data path are the VM, the VPC, and the network firewall.
 
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
 
Anything you'd typically reach for a managed service for (Postgres, Redis, the static site, TLS) is something I'd rather run myself and own end to end. A few reasons for that:
 
**Portability.** The entire data and compute path is a `compose.infra.yml` plus `compose.app.yml` and a `deploy.sh`. Lifting and shifting to Hetzner, EC2, a closet box, or a different GCP project is a hostname change.  

**Control.** When Postgres is a container, I own the version, the conf, the WAL strategy, and the backup story. With Cloud SQL I own none of those, right up until something breaks and I find out I should have.
 
What's left as managed GCP that I *didn't* self-host, with reasoning:
 
| Component | Could self-host? | Why I didn't |
|---|---|---|
| GCS state bucket | Yes (`terraform-backend-git`, an HTTP backend on Caddy) | State surviving a "VM blew up" event is the whole point of remote state. Putting it on the same VM is circular. |
| Artifact Registry | Yes (`registry:2` behind Caddy) | Free tier covers this scale, image artifacts are inherently portable (`crane copy`), and there's a chicken-and-egg with the registry living on the VM that pulls from it. |
| Secret Manager | Yes (SOPS + age, encrypted in git) | Operationally safer: IAM revocation is instant, and no encrypted secret material in git history. A philosophy compromise I'm explicit about. |
| WIF, IAP, billing budget | No equivalent | These are intrinsically per-cloud or required by the rubric. |
 
## Architecture
 
```
                                 https://<vm-ip>.sslip.io
                                            │
                          ┌─────────────────┼──────────────┐
                          │              VM (e2-small)     │
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
                          │                                │
                          │  ┌────────────┐  ┌─────────┐   │
                          │  │ postgres   │  │  redis  │   │
                          │  │ container  │  │container│   │
                          │  │ /opt/app/  │  │(no save)│   │
                          │  │  pgdata    │  │         │   │
                          │  └─────┬──────┘  └─────────┘   │
                          │        │                       │
                          └────────┼───────────────────────┘
                                   │
                                   ▼
                       ┌──────────────────────┐
                       │ google_compute_disk  │
                       │ "pgdata" (10 GB,     │
                       │ pd-balanced, TF-     │
                       │ managed, attached    │
                       │ separately from boot)│
                       └──────────────────────┘
```
 
## Local equals CI
 
Workflows are thin wrappers around `make` targets. Every CI step has a `make` target that runs the same script with the same env contract on your laptop:
 
```bash
make preflight    # validate local tools, print bootstrap tfvars
make test         # run pytest the same way CI does
make tf-plan      # uses the GCS backend; needs WIF auth or local gcloud creds
make ci-pr        # everything the PR workflow does, end to end
make ci-deploy    # everything the main workflow does after `make test`
```
 
`make help` lists the full set. The scripts under `scripts/ci/` are what both CI and Make call.
 
---
 
## Setup (fresh GCP project)
 
The whole bootstrap is one command. You'll need a GCP project with billing enabled, an empty (or new) GitHub repo, and these CLIs installed and authenticated:
 
```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gh auth login                # used by the orchestrator to set GitHub Actions secrets
```
 
Then, from the repo root:
 
```bash
make all-bootstrap
```

After bootstrap finishes, push to trigger the first CI deploy:

```bash
git push -u origin main
```
 
The workflow runs:
 
1. `pytest` against api and worker.
2. WIF auth to GCP.
3. `terraform apply` (no-op if you applied locally first).
4. Build and push the four images to Artifact Registry, tagged with the SHA.
5. Wait for the VM (docker up, `infra.env` written by the startup script).
6. SSH the VM, pull all four images on the host, `docker run` the deploy-tools container. That container brings up postgres and redis (if not already up), waits for both health checks, then runs the canary.
7. Smoke check `https://<domain>/api/version` from CI.

After it succeeds:
 
```bash
cd terraform/main
terraform output web_url           # https://<vm-ip>.sslip.io
curl https://$(terraform output -raw domain)/api/version
curl https://$(terraform output -raw domain)/api/work
```
 
Open the web URL in a browser. The buttons hit `/api/healthz`, `/api/readyz`, `/api/version`, and `/api/work` and render the responses.
 
---

## Useful Links

- successful deploy : https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25215786143
- failure run : https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25215915474
- fixed run : https://github.com/siddarthkay/ulys-hello-world-setup/actions/runs/25216220927i
- terraform destroy output : [`docs/destroy.txt`](docs/destroy.txt)
---

## Service-to-service auth
 
### How `web` reaches `api`
 
Same origin, via Caddy reverse proxy. The static `index.html` is served by Caddy from `/srv/web` at `https://<vm-ip>.sslip.io/` and makes `fetch("/api/...")` calls. Caddy's `handle_path /api/*` block strips the `/api` prefix and reverse-proxies to the active color's container (`api-blue:8080` or `api-green:8080`) on the internal docker network.

### How `api` authenticates to `worker`
 
- **HMAC-SHA256 signed body.** Every request includes `X-Signature: HMAC_SHA256(WORKER_SECRET, body)`. Worker recomputes and rejects on mismatch (returns 401). `WORKER_SECRET` lives in Secret Manager; deploy-tools reads it from the metadata server on every deploy and injects it as a container env var. Pytest covers the rejection paths (missing signature, wrong signature, signature for a different body).

- **Worker network isolation.** The worker container has no published host port. It's only on the internal docker `appnet` bridge, reachable as `worker-<color>:8081` from `api-<color>` and from nothing else. Even root on the VM can't curl it without first being in that network. The HMAC check is defense in depth on top of network isolation, not the only line.

### Other auth boundaries

- **GitHub Actions to GCP:** Workload Identity Federation. The provider has `attribute_condition = "assertion.repository == '<owner>/<repo>'"`, so only this repo's OIDC tokens can mint GCP creds. No JSON keys.
- **GHA to VM:** SSH via IAP only. Public 22/tcp is firewalled to the IAP CIDR. GHA SA has `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`.
- **`api` to Postgres / Redis:** docker bridge network only. Postgres has a password (rotated via Secret Manager). Redis has no auth, which is fine because nothing outside `appnet` can reach it.
---
 
## Architecture decisions and tradeoffs
 
| Decision | Why |
|---|---|
| **Postgres in a container on the VM, not Cloud SQL** | Cloud SQL `db-f1-micro` is ~$9.50/mo and welds the data path to GCP-specific connectivity (PSA range, optional Auth Proxy). Self-hosted Postgres is portable, free above the disk, and gives full control over `postgresql.conf`, extensions, and version pinning. The data dir lives on a TF-managed `google_compute_disk` attached separately from the boot disk, so VM rebuilds don't lose data. |
| **Redis in a container on the VM, not Memorystore** | Memorystore Basic 1 GB is ~$33/mo. It was the single largest line item in the previous shape of this stack. Redis is famously trivial to self-host. The cache is intentionally ephemeral (`--save "" --appendonly no`); the app uses `SETEX` and tolerates a cold cache by definition. |
| **Persistent disk decoupled from boot disk** | A `lifecycle.ignore_changes = [attached_disk]` on the VM and a separate `google_compute_attached_disk` resource means the data disk reattaches to a rebuilt VM. `terraform taint` the VM, re-apply, and the cluster keeps its data. |
| **e2-small VM with Caddy, not Cloud Run per service** | Cloud Run plus the Cloud SQL Auth Proxy plus a Serverless VPC Connector adds three failure modes for very little gain at hello-world scale. The single VM is also where Caddy's auto Let's Encrypt + sslip.io trick fits cleanly. And it's portable: this whole stack runs on any Linux VM with Docker. |
| **sslip.io for TLS** instead of buying a domain | Free, real public DNS, valid for ACME HTTP-01. Tradeoff: not a brand domain. For prod, swap for a real one (Caddyfile change is one line). |
| **Caddy, not nginx** | Caddy auto-handles cert issuance, renewal, and HTTPS redirect with no extra config. nginx + certbot would be three more moving parts. Caddy's `reverse_proxy` also has built-in `weighted_round_robin` which the canary uses. |
| **Artifact Registry** instead of ghcr.io or self-hosted | Spec requires container registry provisioned by TF. AR is the GCP-native option. The VM SA pulls without a separate token; its identity is enough. Self-hosting `registry:2` would add a chicken-and-egg with the registry living on the VM that pulls from it, with no real benefit at this scale. |
| **Secret containers in TF, values added out-of-band** | If we used `random_password` in TF, the value would land in `terraform.tfstate`. Instead TF only references the secrets as data sources; `gcloud secrets versions add` writes the value separately. State only has the resource name. |
| **Bootstrap module separate from main** | The very thing CI authenticates with (WIF + GHA SA) is created by bootstrap, so bootstrap can't run via CI. Budget creation also needs `billing.user`, which is dangerous to delegate. Two TF roots is intentional. |
 
---

## Estimated monthly cost (us-central1, 24/7)
 
| Item | $/mo |
|---|---|
| `e2-small` VM (Debian 12) | ~13.50 |
| 10 GB pd-standard boot disk | ~0.40 |
| 10 GB pd-balanced data disk (pgdata) | ~1.00 |
| Static external IP (in use, attached) | 0.00 |
| Artifact Registry (1 repo, <1 GB) | <0.10 |
| Secret Manager (2 secrets) | <0.10 |
| GCS state bucket (versioned, tiny) | <0.05 |
| GCS deploy-state bucket (one tiny object) | <0.01 |
| Logging + egress | <1.00 |
| **Total** | **~$16.15/mo** |
 

The cost line that *actually* matters is "what would it take to move clouds," and the answer here is "change `region` in tfvars and pick a different IaC provider."
 
---

## Operating notes
 
A few things worth being explicit about, because "we run our own data stores" means owning a few responsibilities GCP would otherwise handle.
 
### Postgres password rotation
 
`POSTGRES_PASSWORD` is honored *only* on the first boot of an empty data dir. Once Postgres has bootstrapped, changing the env var has no effect. The password stored in `pg_authid` is the one that matters. So:
 
- **First deploy:** the value in Secret Manager is the password, full stop.
- **Subsequent rotations:** update Secret Manager, SSH the VM, `docker exec -it postgres psql -U app -d app -c "ALTER USER app WITH PASSWORD '<new>';"`, then trigger a deploy so the api containers pick up the new value from SM. Or run the rotation on next deploy as a step in `deploy.sh`. Not currently automated; called out as a known gap.

### Postgres and Redis upgrades
 
Pinned to `postgres:16-alpine` and `redis:7-alpine`. Bumping major versions is a tagged-image change. Postgres major upgrades in particular need `pg_upgrade` or a `pg_dump`/`pg_restore` round-trip, same as anywhere else.
 
---
 
## Adding a second environment (staging vs prod)
 
The current code targets a single environment. Promoting to `staging` plus `prod` is a change where the *isolation strategy* matters more than the directory layout.
 
### Separate GCP projects per environment

This is the option I'd pick if budget and org structure permitted. Strongest isolation, simplest mental model: each environment is its own world.
 
**Project layout:**
- `ulys-app-staging` and `ulys-app-prod`, each its own GCP project.
- Each has its own billing budget, VPC, VM, attached pgdata disk, Secret Manager, Artifact Registry, state bucket, GHA SA, and WIF binding.
- Each project's Terraform state lives in that project's own GCS bucket. No shared state, no cross-env IAM blast radius.
**TF code layout:**
```
terraform/
  bootstrap/             unchanged single-env bootstrap, run per project
  modules/
    app/                 today's main/*.tf, parameterised by var.environment
  envs/
    staging/main.tf      calls module.app with staging-specific tfvars
    prod/main.tf         calls module.app with prod-specific tfvars
```
 
Today's `terraform/main/*.tf` becomes `terraform/modules/app/`. Each env-root is a tiny file (~10 lines) that calls the module and supplies env-specific values. Adding a third env (e.g. `dev`) is a copy-paste of the env-root file.

**Why per-project beats workspaces:**
- *Blast radius:* a `terraform destroy` typo in staging physically cannot touch prod. Different project, different IAM. With workspaces, both envs share the same provider config and same project; one wrong workspace switch wipes prod.
- *IAM:* "who can apply prod" becomes "who has admin on the prod project," not "who has access to one folder in the state bucket." Cleaner audit.
- *Quotas + billing:* per-env budget alerts route to per-env owners. Prod cost overruns can't hide inside staging spend.

### CI: one workflow, environment-aware
 
GitHub Environments (`staging` and `prod`) gate which job uses which secrets. The build step runs once and produces a SHA-tagged image; deploy is invoked per environment with that exact SHA, never rebuilt.

```yaml
jobs:
  build:                       # runs once, tags image with SHA, pushes to a shared
    ...                        # Artifact Registry repo (registry-only project, optional)
 
  deploy-staging:
    needs: build
    environment: staging       # secrets resolved from staging env settings
    steps:
      - run: make ci-deploy
        env:
          TF_ENV: staging
          IMAGE_TAG: ${{ github.sha }}
 
  deploy-prod:
    needs: deploy-staging
    environment: prod          # required reviewers configured in repo settings
    steps:
      - run: make ci-deploy
        env:
          TF_ENV: prod
          IMAGE_TAG: ${{ github.sha }}
```
 
WIF's `attribute_condition` is extended to bind GitHub's `environment` claim:
 
```hcl
attribute_condition = <<-EOT
  assertion.repository == '<owner>/<repo>' &&
  assertion.environment == '${var.environment}'
EOT
```
 
Even if a workflow steals the prod secrets, GCP rejects the federation token unless the run is happening inside `environment: prod`, which the repo settings only allow after a human approval click.
 
### Image promotion model
 
The single image SHA flows: build, staging, prod. CI never rebuilds prod; it re-runs the deploy step against the prod project with the same `IMAGE_TAG`. "What's running in prod" is identical to "what was in staging when it passed." A `promote.yml` workflow with `workflow_dispatch` lets you re-deploy any historical SHA without going back through git.
 

### Alternative: workspaces
 
If org policy or budget forbids multiple GCP projects, per-env Terraform workspaces inside a single project, with name prefixes (`ulys-staging-vm`, `ulys-prod-vm`) and separate GHA SAs gated by per-workspace IAM, is the next-best. This is what most small teams end up doing. You lose the project-level blast radius isolation.
 
---
 
## What I'd add for production
 
- **HA compute:** managed instance group with a regional health-checked LB instead of one VM. Single VM is a SPOF and a reboot is a brief outage. Caveat: this collides with self-hosted Postgres on local disk. At HA you need either Patroni-style Postgres replication, an attached regional persistent disk, or honest Cloud SQL. The "do it yourself" answer that scales is Patroni + etcd; the "buy" answer is Cloud SQL HA + PITR.
- **Postgres backups:** cron'd `pg_dump | gcloud storage cp <bucket-with-retention>` plus periodic restore drills. Without this, "self-hosted" is one disk failure away from data loss.
- **Postgres password rotation flow:** scripted via `deploy.sh` so SM rotation actually propagates to the running cluster (currently manual).
- **Memorystore Standard or Redis Sentinel** if cache loss becomes a real availability problem (it isn't here).
- **Custom domain + Cloud DNS:** drop sslip.io for a real DNS zone, managed by TF.
- **VPC Service Controls:** lock Secret Manager and Artifact Registry behind a perimeter so a leaked SA token can't be abused from outside the org's networks.
- **Image scanning** (Trivy) and SBOM generation in CI; cosign signatures verified at deploy.
- **Smarter canary:** SLO-based gates (latency p99, error rate from real metrics, not just curl probes), with a hold time at each stage to catch slow-burn failures.
- **Database migrations** with a versioned tool (alembic / golang-migrate / sqitch). Currently `CREATE TABLE IF NOT EXISTS` runs in the request path; fine for one table, awful for real apps.
- **Observability stack:** OpenTelemetry collector to Cloud Operations or Grafana. Currently just stdout logs.
- **Tightened IAM:** the GHA SA has broad admin-tier roles in bootstrap. Production should split plan-only and apply roles, with apply gated on env approval.
- **Scheduled `terraform plan` drift detection** that opens a PR if the world doesn't match the code.
- **State bucket DR:** cross-region replica or a daily export to a separate project so a project-delete fat-finger doesn't lose everything.

---
