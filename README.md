<div align="center">

# Prima Tech Challenge — User API

**A production-shaped REST API on AWS, from source code to a running pod.**

FastAPI · DynamoDB · S3 · Docker · Terraform · Helm · GitHub Actions

[![CI](https://github.com/ferjosem362/prima-tech-challenge/actions/workflows/ci.yml/badge.svg)](https://github.com/ferjosem362/prima-tech-challenge/actions/workflows/ci.yml)
[![CD](https://github.com/ferjosem362/prima-tech-challenge/actions/workflows/cd.yml/badge.svg)](https://github.com/ferjosem362/prima-tech-challenge/actions/workflows/cd.yml)
[![Python 3.12](https://img.shields.io/badge/python-3.12-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Terraform](https://img.shields.io/badge/terraform-1.9-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Helm](https://img.shields.io/badge/helm-3.16-0F1689?logo=helm&logoColor=white)](https://helm.sh/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

## Table of contents

- [What this is](#what-this-is)
- [The five tasks](#the-five-tasks)
- [Repository structure](#repository-structure)
- [Quick start](#quick-start)
- [The API](#the-api)
- [Architecture](#architecture)
- [Key decisions](#key-decisions)
- [Testing](#testing)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Known limits and next steps](#known-limits-and-next-steps)

---

## What this is

A small REST API that registers users with an avatar image and lists them back.
Users are persisted in **DynamoDB**, avatars in **S3**.

| Method | Path     | Description                                 |
| ------ | -------- | ------------------------------------------- |
| `GET`  | `/users` | Retrieve a list of all users                |
| `POST` | `/user`  | Create a user, uploading an image as avatar |

Plus `GET /health/live`, `GET /health/ready` and interactive OpenAPI docs at `/docs`.

Everything runs locally against **LocalStack CE** — no AWS account, no cost,
no EKS cluster required.

---

## The five tasks

| # | Task | Deliverable | Where |
| - | ---- | ----------- | ----- |
| 1 | Python API Server | FastAPI in ports-and-adapters layout, DynamoDB persistence, S3 uploads, RFC 9457 error handling | [`app/`](app/) · [`tests/`](tests/) |
| 2 | Dockerise | Multi-stage build, non-root user, healthcheck, OCI labels, compose stack | [`Dockerfile`](Dockerfile) · [`docker-compose.yml`](docker-compose.yml) |
| 3 | Infrastructure as Code | Terraform: DynamoDB, S3, least-privilege IAM, **IRSA for Kubernetes ServiceAccounts**, EKS platform roles | [`infra/terraform/`](infra/terraform/) |
| 4 | Kubernetes with Helm | Custom chart: autoscaling, three health probes, PDB, restricted PodSecurity, NetworkPolicy, `helm test` | [`deploy/helm/prima-api/`](deploy/helm/prima-api/) |
| 5 | CI/CD | GitHub Actions: quality gate, security scanning, IaC plan, chart validation, signed images, gated deploy | [`.github/workflows/`](.github/workflows/) |

Full design rationale and operations guide: **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.

---

## Repository structure

```
prima-tech-challenge/
│
├── app/                                  # Task 1 — the application
│   ├── main.py                           #   ASGI factory, middleware, correlation IDs
│   ├── api/                              #   HTTP edge: routes and dependency wiring
│   │   ├── deps.py                       #     the only place ports are bound to adapters
│   │   └── v1/  users.py · health.py     #     GET /users, POST /user, probes
│   ├── schemas/user.py                   #   Pydantic DTOs — the public contract
│   ├── services/                         #   use cases
│   │   ├── user_service.py               #     orchestration + compensating rollback
│   │   └── images.py                     #     magic-byte sniffing, size guard rails
│   ├── domain/                           #   entities + ports — zero third-party imports
│   │   ├── models.py                     #     User, Page
│   │   └── ports.py                      #     UserRepository, AvatarStorage (Protocols)
│   ├── infrastructure/                   #   adapters
│   │   ├── dynamodb_user_repository.py   #     conditional writes, cursor pagination
│   │   ├── s3_avatar_storage.py          #     upload, delete, healthcheck
│   │   └── aws.py                        #     cached boto3 clients, retry/timeout config
│   └── core/                             #   config · JSON logging · errors · thread offload
│
├── tests/                                # unit + integration (AWS emulated by moto)
│   ├── test_service_unit.py              #   orchestration against in-memory fakes
│   ├── test_users_api.py                 #   full HTTP round-trip, exact item shape
│   └── test_error_handling.py            #   every failure path returns problem+json
│
├── Dockerfile                            # Task 2 — multi-stage, non-root, healthcheck
├── docker-compose.yml                    #   LocalStack + provisioner + API
├── .dockerignore
│
├── infra/terraform/                      # Task 3 — one module, two targets
│   ├── dynamodb.tf                       #   users table (PK: email), SSE, PITR
│   ├── s3.tf                             #   versioned, encrypted, public access blocked
│   ├── iam.tf                            #   app policy · IRSA trust · EKS roles · GitHub OIDC
│   ├── providers.tf                      #   dynamic endpoints -> LocalStack or real AWS
│   ├── variables.tf · locals.tf · outputs.tf · versions.tf
│   ├── backend.tf.example                #   S3 remote state for shared environments
│   └── envs/  localstack.tfvars · aws.tfvars.example
│
├── deploy/helm/prima-api/                # Task 4 — the chart
│   ├── Chart.yaml
│   ├── values.yaml                       #   production-shaped defaults
│   ├── values-localstack.yaml            #   minikube overlay
│   ├── values-eks.yaml                   #   real cluster overlay (IRSA, ALB, NetworkPolicy)
│   └── templates/
│       ├── deployment.yaml               #   probes, security context, config checksum
│       ├── hpa.yaml                      #   autoscaling/v2, asymmetric behaviour
│       ├── pdb.yaml · service.yaml · ingress.yaml
│       ├── serviceaccount.yaml           #   IRSA annotation
│       ├── configmap.yaml · secret.yaml  #   local-only static credentials
│       ├── networkpolicy.yaml · servicemonitor.yaml
│       ├── _helpers.tpl                  #   naming, labels, fail-fast validation
│       ├── NOTES.txt
│       └── tests/test-api.yaml           #   `helm test` smoke pod
│
├── .github/                              # Task 5 — automation
│   ├── workflows/
│   │   ├── ci.yml                        #   quality · security · iac · helm · image · smoke
│   │   ├── cd.yml                        #   promote digest, publish chart, gated deploy
│   │   └── security-nightly.yml          #   re-scan the released image daily
│   ├── dependabot.yml
│   └── PULL_REQUEST_TEMPLATE.md
│
├── scripts/
│   ├── preflight.sh                      # check tooling on Ubuntu, print install commands
│   ├── bootstrap_repo.sh                 # create the GitHub repo and push
│   ├── bootstrap_local.sh                # idempotent LocalStack provisioning
│   ├── minikube_up.sh                    # cluster + infra + image + Helm, one command
│   └── smoke.sh                          # end-to-end curl walkthrough
│
├── docs/ARCHITECTURE.md                  # solution architecture, decisions, runbook
├── Makefile                              # single entry point for every task
├── pyproject.toml                        # ruff · mypy · pytest configuration
├── requirements.txt · requirements-dev.txt
├── .env.example
└── LICENSE
```

---

## Quick start

> Tested on Ubuntu 22.04/24.04 and Fedora 40+, including under WSL2.
> Every path below runs entirely on your machine — no AWS account involved.

### 0. Prerequisites

```bash
./scripts/preflight.sh
```

Checks every tool and prints the exact install command for whatever is missing —
it never installs anything by itself. Required: `python3`, `docker`, `git`,
`terraform`, `aws`, `kubectl`, `helm`, `minikube`. Optional: `gh`, `jq`, `trivy`.

> After installing Docker, log out and back in (or run `newgrp docker`) so your
> user picks up the `docker` group.

### 1. Just the API — only Docker needed

```bash
make up        # LocalStack + table + bucket + API  ->  http://localhost:8000/docs
make smoke     # create a user, hit the duplicate guard, list them back
make down
```

### 2. Infrastructure with Terraform

```bash
docker compose up -d localstack
make tf-apply  # DynamoDB table + S3 bucket + IAM role, inside LocalStack CE
make tf-output # names and ARNs, ready to feed into Helm

aws --endpoint-url http://localhost:4566 dynamodb scan --table-name users
aws --endpoint-url http://localhost:4566 s3 ls s3://prima-tech-challenge/avatars/
```

### 3. Full Kubernetes deployment

```bash
make k8s-up    # minikube + LocalStack + Terraform + image build + Helm + helm test
kubectl get all -n prima
kubectl port-forward -n prima svc/prima-api 8000:80
./scripts/smoke.sh http://localhost:8000
make k8s-down
```

### 4. Development loop

```bash
make install   # virtualenv + dev dependencies
make test      # ~25 tests, no AWS credentials needed (moto)
make verify    # everything CI checks, locally
make run       # uvicorn with hot reload
make help      # every available target
```

---

## The API

```bash
# Create a user
curl -X POST http://localhost:8000/user \
  -F "name=Test User" \
  -F "email=test-user@prima.it" \
  -F "avatar=@./my-avatar.png;type=image/png"

# List users
curl http://localhost:8000/users
```

`GET /users` returns exactly the documented shape — a bare JSON array:

```json
[
  {
    "avatar_url": "https://prima-tech-challenge.s3.us-east-1.amazonaws.com/avatars/9f1c.png",
    "email": "test-user@prima.it",
    "name": "Test User"
  }
]
```

and the DynamoDB item is stored in the native attribute format:

```json
{
  "name":       { "S": "Test User" },
  "avatar_url": { "S": "https://prima-tech-challenge.s3.us-east-1.amazonaws.com/avatars/9f1c.png" },
  "email":      { "S": "test-user@prima.it" }
}
```

### Error contract

Every failure returns `application/problem+json` (RFC 9457) with the correlation ID.
A stack trace never reaches a client.

| Status | `code` | When |
| ------ | ------ | ---- |
| `400` | `validation_failed` | Bad name or email, missing field |
| `400` | `invalid_cursor` | Malformed pagination token |
| `409` | `user_already_exists` | Email already registered |
| `413` | `avatar_too_large` | Over `MAX_AVATAR_BYTES` |
| `415` | `unsupported_avatar_type` | Not a real PNG/JPEG/GIF/WebP |
| `503` | `repository_unavailable` | DynamoDB error |
| `503` | `storage_unavailable` | S3 error |

---

## Architecture

```
                    ┌──────────────────────────────────────────────┐
   client ─────────►│  Ingress (ALB)  ──►  Service  ──►  Pods       │
                    │                                   prima-api  │
                    │                        ▲              │      │
                    │                    HPA │      ServiceAccount │
                    │                (CPU/memory)    + IRSA role   │
                    └───────────────────────────────────────┼──────┘
                             EKS / minikube                 │ short-lived
                                                            │ STS credentials
                                              ┌─────────────┴─────────────┐
                                              ▼                           ▼
                                        DynamoDB table               S3 bucket
                                        (users, PK=email)          (avatars/*)
```

The application itself is ports and adapters — the dependency arrow always points
inwards, so the business rules never import FastAPI or boto3:

```
   HTTP  ─►  app/api/          routes, DI wiring, request/response mapping
             app/schemas/      Pydantic DTOs (the public contract)
                 │
                 ▼
             app/services/     use cases, orchestration, upload guard rails
                 │
                 ▼  (Protocols)
             app/domain/       entities + ports — zero third-party imports
                 ▲
                 │  (implements)
             app/infrastructure/   DynamoDB + S3 adapters, boto3 clients
```

Why it pays off: the service layer is tested with in-memory fakes (no mocks, no
AWS, milliseconds), swapping DynamoDB for Postgres means writing one adapter,
and error translation happens once, at the edge.

---

## Key decisions

<details>
<summary><b>Application</b> — data model, consistency, upload safety</summary>

**`email` is the DynamoDB partition key.** The natural business identifier, and
it turns uniqueness into a single conditional write
(`attribute_not_exists(email)`) instead of a read-then-write with a race window.

**Writes are ordered so failures are benign.** S3 first, DynamoDB second. If the
conditional write is rejected or the table is unavailable, a compensating
`delete_object` removes the avatar. Worst case is a short-lived orphan object —
never a user row pointing at an image that does not exist. A test pins it down.

**Uploads are never trusted.** The `Content-Type` of a multipart part is
attacker-controlled, so images are identified by their **magic bytes**. Body size
is enforced while streaming, so an oversized upload is rejected after the first
chunk over the limit rather than after buffering the whole thing.

**Object keys are random UUIDs**, never the email or the client's filename — keys
leak into public URLs and access logs, and a client-supplied name invites path
traversal and avatar overwrites.

**boto3 is synchronous, the handlers are not.** Every AWS call is offloaded to
AnyIO's worker-thread pool, so a slow DynamoDB response cannot block the event
loop and serialise every other request.

**Pagination without breaking the contract.** `GET /users` must return a bare
array, so the cursor travels in the `X-Next-Cursor` header and `?limit=&cursor=`
are optional query parameters.

</details>

<details>
<summary><b>Infrastructure</b> — least privilege and IRSA</summary>

**One module, two targets.** The same Terraform root targets LocalStack and real
AWS; only the tfvars file changes. No second copy of the code to drift out of
sync with the one you actually tested.

**Least privilege, concretely.** The app policy grants only the five DynamoDB
verbs the code calls, on that one table ARN — no `DeleteItem`, no `UpdateItem`,
no wildcard. On S3 it is scoped to `avatars/*`, and `ListBucket` carries an
`s3:prefix` condition so it cannot enumerate the rest of the bucket.

**IRSA, end to end.** The cluster's OIDC issuer is registered as an IAM identity
provider; the role's trust policy accepts `AssumeRoleWithWebIdentity` only when
`sub == system:serviceaccount:prima:prima-api` **and** `aud == sts.amazonaws.com`.
Both conditions matter: `sub` pins the exact ServiceAccount, `aud` stops a token
minted for another audience from being replayed. Result: no credentials exist
anywhere in the cluster, and they rotate themselves.

**LocalStack CE has no EKS**, so `enable_irsa` defaults to `false` there — the
role, its policy and every output are created identically, only the trust
statement falls back to account-root. The AWS path is a tfvars flip, not a code
change.

**The bucket blocks public access entirely.** Avatars are meant to be served
through CloudFront with an Origin Access Control, or with presigned URLs — never
by making a bucket world-readable.

</details>

<details>
<summary><b>Kubernetes</b> — availability, reliability, security</summary>

**Three probes, not one.** Liveness hits `/health/live`, which never touches AWS:
a probe that depends on a downstream service turns a partial outage into a total
one. Readiness hits `/health/ready`, which does check the table and bucket, so a
broken pod is pulled out of the Service instead of failing user requests. A
startup probe covers cold starts without loosening either.

**Autoscaling that does not flap.** HPA v2 on CPU *and* memory, with asymmetric
`behavior`: scale out fast (30 s window), scale in slowly (300 s). `replicas` is
omitted from the Deployment when the HPA is enabled — otherwise every
`helm upgrade` would reset the autoscaler's decision.

**Zero-downtime rollouts.** `maxUnavailable: 0`, a PodDisruptionBudget so node
drains cannot take the service to zero, zone spread constraints, and a
`preStop: sleep 5` because endpoint withdrawal and SIGTERM race each other.

**Config changes actually take effect.** A `checksum/config` annotation rolls the
pods when the ConfigMap changes; without it an edit silently leaves the old
values running.

**Restricted PodSecurity profile**: non-root, read-only root filesystem (with an
in-memory `emptyDir` for `/tmp`), all capabilities dropped, `RuntimeDefault`
seccomp, and the ServiceAccount token not mounted — the app never calls the
Kubernetes API. `_helpers.tpl` fails the render outright if IRSA and static
credentials are both configured.

</details>

<details>
<summary><b>CI/CD</b> — supply chain and promotion model</summary>

**CI proves an artifact is good; CD promotes it.** CD never rebuilds from source —
it re-tags the digest CI already tested, so what runs in production is
byte-for-byte what passed the gate.

**The quality gate**: ruff (lint + format), mypy strict, pytest with coverage;
gitleaks, Trivy (vulns, misconfig, secrets) and hadolint with SARIF uploaded to
the Security tab; `terraform fmt/validate` + Checkov + a **real plan against a
LocalStack service container**, which catches provider mistakes a `validate`
waves through; `helm lint --strict` on all three overlays, kubeconform against
the Kubernetes schema, and a policy scan of the *rendered* manifests.

**Supply chain**: images carry an SBOM and SLSA provenance and are signed with
**cosign keyless** — identity comes from the workflow's OIDC token, so there is
no private key to store or rotate.

**No credentials anywhere.** moto for the tests, LocalStack for the plan, GitHub
OIDC role assumption for deployments. GHCR login is skipped on pull requests so a
fork can never obtain a push token.

**The deploy job is opt-in** (`vars.DEPLOY_ENABLED`, default `false`) behind a
protected environment, because the brief says explicitly not to create a real EKS
cluster. It uses `helm upgrade --atomic --wait`, which rolls back automatically
if the new pods never turn ready.

</details>

---

## Testing

```bash
make test        # ~25 tests, no AWS account needed
make cov         # HTML coverage report
make verify      # lint + types + tests + helm lint + terraform fmt
```

| Layer | File | What it proves |
| ----- | ---- | -------------- |
| Unit | `tests/test_service_unit.py` | Write ordering and the compensating delete, against in-memory fakes |
| Integration | `tests/test_users_api.py` | Full HTTP round-trip through moto: exact DynamoDB item shape, real bytes in S3, cursor pagination |
| Error paths | `tests/test_error_handling.py` | Every status in the table above, including a shell script disguised as a PNG and the orphan-cleanup check |

---

## Configuration

Every setting is an environment variable (see [`.env.example`](.env.example));
nothing is hard-coded and the app handles no credentials itself — boto3 resolves
them from the standard chain (env, shared config, instance role, IRSA).

| Variable | Default | Notes |
| -------- | ------- | ----- |
| `ENVIRONMENT` | `local` | `local` · `dev` · `prod` |
| `LOG_LEVEL` | `INFO` | JSON logs, one object per line |
| `AWS_REGION` | `us-east-1` | |
| `AWS_ENDPOINT_URL` | *(unset)* | Set for LocalStack/MinIO |
| `DYNAMODB_TABLE` | `users` | |
| `S3_BUCKET` | `prima-tech-challenge` | |
| `S3_PUBLIC_BASE_URL` | *(derived)* | Point at CloudFront in production |
| `MAX_AVATAR_BYTES` | `2097152` | 2 MiB |
| `DEBUG_ERRORS` | `false` | Must stay false outside local development |

---

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `permission denied` on the Docker socket | Your user is not in the `docker` group: `sudo usermod -aG docker $USER && newgrp docker` |
| Pods stuck in `CrashLoopBackOff` on minikube | They cannot reach LocalStack. Start it with `GATEWAY_LISTEN=0.0.0.0:4566` — the default loopback binding is unreachable from the cluster. `scripts/minikube_up.sh` handles this |
| `helm test` fails on readiness | The table or bucket does not exist yet: run `make tf-apply` before deploying |
| HPA reports `<unknown>` for CPU | The metrics server is missing: `minikube addons enable metrics-server` |
| `ResourceNotFoundException` on the first request | The provisioner did not finish. `docker compose up` orders it correctly; if you started the API alone, run `./scripts/bootstrap_local.sh` |
| Terraform complains about credentials | Against LocalStack any values work: `export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test` |
| `Cannot connect to the Docker daemon` on WSL | Either enable Docker Desktop's WSL integration for the distro, or run the daemon inside it — which needs systemd: add `[boot]\nsystemd=true` to `/etc/wsl.conf`, run `wsl --shutdown` from PowerShell, then `sudo systemctl enable --now docker` |
| minikube fails to start on WSL | Use the docker driver (`--driver=docker`) and give WSL ~4 GB in `%USERPROFILE%\.wslconfig` |

---

## Accepted risks

Security tooling findings are either fixed or accepted in writing — never
silenced. The current exceptions live in [`.trivyignore`](.trivyignore) and
`skip_check` in the `iac` job, each with its rationale:

| Finding | Decision |
| ------- | -------- |
| `AWS-0132` — bucket not encrypted with a customer managed key | Accepted. Public avatar images, no PII, random UUID keys; SSE-S3 already encrypts at rest. A CMK would add key policy, rotation and cost without changing the risk profile. Revisit if the bucket ever holds anything else |

---

## Known limits and next steps

- **`GET /users` uses `Scan`**, which is O(table). Fine at this scale and already
  paginated, but at real volume the listing belongs on a GSI with a bucketed
  partition key, or on a read projection.
- **Serve avatars via CloudFront + Origin Access Control** and keep the bucket
  private; or hand the browser a presigned POST so large images never transit
  the API at all.
- **No authentication.** `POST /user` is the expensive, abusable endpoint and
  would need JWT/Cognito plus per-IP rate limiting.
- **No metrics endpoint yet.** The chart ships a `ServiceMonitor`; the app needs
  `/metrics` and OpenTelemetry traces spanning API → DynamoDB → S3.
- **GitHub Actions are pinned to tags, not digests.** Dependabot keeps them
  fresh; digest pinning is the stricter supply-chain posture.

---

<div align="center">
<sub>Built for the Prima tech challenge · <a href="docs/ARCHITECTURE.md">Architecture &amp; runbook</a> · <a href="LICENSE">MIT</a></sub>
</div>
