# Makefile for ulys-devops-take-home
#
# Most CI logic lives in scripts/ci/*.sh; this is the dispatch layer.
# `make help` lists everything.
#
# Local usage: export the canonical env vars (the same names CI uses) and run
# the same targets the workflows do. The workflows are intentionally thin
# wrappers around `make ...` so you can reproduce any CI step on your laptop.
#
# Required env for most targets:
#   GCP_PROJECT_ID         your GCP project ID
#   GCP_TF_STATE_BUCKET    state bucket name (bootstrap output)
#   GCP_WIF_PROVIDER       full WIF provider resource (bootstrap output)
#   GCP_GHA_SA_EMAIL       gha service account email (bootstrap output)
#   GITHUB_REPO            owner/repo (auto-set in CI as $GITHUB_REPOSITORY)

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

CI := scripts/ci

# Canonicalize: in CI, GitHub sets GITHUB_REPOSITORY; locally users set GITHUB_REPO.
ifndef GITHUB_REPO
  ifdef GITHUB_REPOSITORY
    export GITHUB_REPO := $(GITHUB_REPOSITORY)
  endif
endif

.PHONY: help
help: ## list available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- developer-facing ---------------------------------------------------

.PHONY: preflight
preflight: ## sanity-check local tools + print bootstrap tfvars
	@bash scripts/preflight.sh

.PHONY: bootstrap-finish
bootstrap-finish: ## emit main tfvars, populate Secret Manager + Cloud SQL pwd
	@bash scripts/bootstrap-finish.sh

.PHONY: destroy
destroy: ## ordered teardown: main → bootstrap → state bucket
	@bash scripts/destroy.sh

.PHONY: destroy-keep-bootstrap
destroy-keep-bootstrap: ## destroy main only; keep bootstrap so re-deploy is one apply away
	@bash scripts/destroy.sh --keep-bootstrap

# ---- tests + tf checks (used by PR workflow) ----------------------------

.PHONY: test
test: ## run pytest for api and worker
	@bash $(CI)/test.sh

.PHONY: tf-fmt
tf-fmt: ## terraform fmt -check -recursive
	@bash $(CI)/tf-fmt.sh

.PHONY: tf-init
tf-init: ## terraform init main with GCS backend
	@bash $(CI)/tf-init.sh

.PHONY: tf-validate
tf-validate: ## terraform validate main
	@bash $(CI)/tf-validate.sh

.PHONY: tf-plan
tf-plan: ## terraform plan main; writes terraform/main/plan.txt
	@bash $(CI)/tf-plan.sh

.PHONY: tf-apply
tf-apply: ## terraform apply main
	@bash $(CI)/tf-apply.sh

.PHONY: tf-output
tf-output: ## emit terraform outputs as key=value lines (eval-able)
	@bash $(CI)/tf-output.sh

.PHONY: post-plan-comment
post-plan-comment: ## post terraform/main/plan.txt as a PR comment (needs GITHUB_TOKEN, PR_NUMBER)
	@bash $(CI)/post-plan-comment.sh

# ---- deploy pipeline (used by main workflow) ----------------------------

.PHONY: build-push
build-push: ## build api+worker images and push to Artifact Registry
	@bash $(CI)/build-push.sh

.PHONY: wait-vm
wait-vm: ## wait for the VM startup script to finish
	@bash $(CI)/wait-vm.sh

.PHONY: scp-deploy
scp-deploy: ## copy deploy/ + app/web/ to the VM
	@bash $(CI)/scp-deploy.sh

.PHONY: run-canary
run-canary: ## SSH to VM and run deploy.sh (10/50/100 canary + auto-rollback)
	@bash $(CI)/run-canary.sh

.PHONY: smoke-public
smoke-public: ## hit https://DOMAIN/api/version after promote
	@bash $(CI)/smoke-public.sh

.PHONY: deploy
deploy: wait-vm scp-deploy run-canary smoke-public ## full VM-side deploy chain (no build, no apply)

# ---- composite targets used by workflows -------------------------------

.PHONY: ci-pr
ci-pr: test tf-fmt tf-init tf-validate tf-plan ## what the PR workflow runs

.PHONY: ci-deploy
ci-deploy: tf-init tf-apply build-push deploy ## what the main workflow runs after `test`

# ---- housekeeping ------------------------------------------------------

.PHONY: clean
clean: ## remove local terraform state caches + plan files + venvs
	rm -rf terraform/main/.terraform terraform/bootstrap/.terraform
	rm -f  terraform/main/plan.bin terraform/main/plan.txt
	rm -rf .pytest_cache app/api/.pytest_cache app/worker/.pytest_cache
