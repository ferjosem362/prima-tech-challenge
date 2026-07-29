# Self-documenting Makefile: `make` (or `make help`) lists every target.
# One entry point for the whole challenge — app, infra, cluster and CI.
.DEFAULT_GOAL := help
SHELL := /bin/bash
COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")


VENV       ?= .venv
PY         := $(VENV)/bin
TF         := terraform -chdir=infra/terraform
CHART      := deploy/helm/prima-api
NAMESPACE  ?= prima
RELEASE    ?= prima-api
IMAGE      ?= prima-tech-challenge:local

.PHONY: help preflight install lint format typecheck test cov run \
        up down logs smoke build \
        tf-init tf-plan tf-apply tf-destroy tf-fmt tf-output \
        helm-lint helm-template k8s-up k8s-test k8s-down \
        repo verify clean

help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Prerequisites ---------------------------------------------------------
preflight:  ## Check that every required tool is installed (Ubuntu)
	./scripts/preflight.sh

install:  ## Create the virtualenv and install dev dependencies
	python3 -m venv $(VENV) && $(PY)/pip install --upgrade pip \
		&& $(PY)/pip install -r requirements-dev.txt

# --- Task 1: application ---------------------------------------------------
lint:  ## Lint with ruff
	$(PY)/ruff check app tests && $(PY)/ruff format --check app tests

format:  ## Auto-format and autofix
	$(PY)/ruff format app tests && $(PY)/ruff check --fix app tests

typecheck:  ## Type-check with mypy (strict)
	$(PY)/mypy app

test:  ## Run the test-suite (AWS emulated with moto)
	$(PY)/pytest

cov:  ## Test-suite with an HTML coverage report
	$(PY)/pytest --cov-report=html && echo "open htmlcov/index.html"

run:  ## Run the API locally with hot reload
	$(PY)/uvicorn app.main:app --reload --port 8000

# --- Task 2: containers ----------------------------------------------------
build:  ## Build the container image
	docker build -t $(IMAGE) --build-arg VCS_REF=$$(git rev-parse --short HEAD 2>/dev/null || echo dev) .

up:  ## Start LocalStack + provisioner + API with docker compose
	docker compose up --build -d && docker compose logs -f api

down:  ## Tear the local stack down
	docker compose down -v

logs:  ## Tail the API logs
	docker compose logs -f api

smoke:  ## Exercise the running API end to end
	./scripts/smoke.sh

# --- Task 3: infrastructure as code ---------------------------------------
tf-init:  ## terraform init
	$(TF) init -input=false

tf-fmt:  ## Format the Terraform code
	$(TF) fmt -recursive

tf-plan: tf-init  ## Plan against LocalStack
	$(TF) plan -var-file=envs/localstack.tfvars -input=false

tf-apply: tf-init  ## Create the AWS resources in LocalStack
	$(TF) apply -auto-approve -input=false -var-file=envs/localstack.tfvars

tf-output:  ## Show the Terraform outputs
	$(TF) output

tf-destroy:  ## Destroy the LocalStack resources
	$(TF) destroy -auto-approve -var-file=envs/localstack.tfvars

# --- Task 4: Kubernetes ----------------------------------------------------
helm-lint:  ## Lint the chart against every values overlay
	@for v in values.yaml values-localstack.yaml values-eks.yaml; do \
		echo "--- $$v"; helm lint $(CHART) --strict -f $(CHART)/$$v || exit 1; \
	done

helm-template:  ## Render the manifests to stdout
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-eks.yaml

k8s-up:  ## Full local deployment: minikube + LocalStack + Terraform + Helm
	./scripts/minikube_up.sh

k8s-test:  ## Run the chart's smoke test inside the cluster
	helm test $(RELEASE) -n $(NAMESPACE)

k8s-down:  ## Remove the release and stop the local stack
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete namespace $(NAMESPACE)
	-docker compose down -v

# --- Task 5: CI/CD ---------------------------------------------------------
repo:  ## Create the GitHub repository and push (needs the gh CLI)
	./scripts/bootstrap_repo.sh

verify: lint typecheck test helm-lint  ## Everything CI checks, locally
	$(TF) fmt -check -recursive
	@echo "All local checks passed."

clean:  ## Remove caches and build leftovers
	rm -rf .pytest_cache .mypy_cache .ruff_cache htmlcov .coverage *.tgz
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

tf-reset:  ## Clean slate: wipe LocalStack and the local state, then re-apply
	-$(COMPOSE) down -v
	rm -f infra/terraform/terraform.tfstate infra/terraform/terraform.tfstate.backup
	$(COMPOSE) up -d localstack
	@echo "waiting for LocalStack..."
	@for i in $$(seq 1 60); do curl -fs http://localhost:4566/_localstack/health >/dev/null 2>&1 && break; sleep 1; done
	$(MAKE) tf-apply
