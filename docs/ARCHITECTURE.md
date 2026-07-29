# Solution architecture

This document covers the whole solution: how the pieces fit together, why each
decision was made, and how to run everything from a clean Ubuntu machine.

---

## 1. Overview

```
                    ┌──────────────────────────────────────────────┐
   client ─────────►│  Ingress (ALB)  ──►  Service  ──►  Pods       │
                    │                                   prima-api  │
                    │                        ▲              │      │
                    │                        │              │      │
                    │                    HPA │      ServiceAccount │
                    │                  (CPU/mem)     + IRSA role   │
                    └───────────────────────────────────────┼──────┘
                                  EKS / minikube            │
                                                            │ short-lived
                                                            │ STS credentials
                                              ┌─────────────┴─────────────┐
                                              ▼                           ▼
                                        DynamoDB table               S3 bucket
                                        (users, PK=email)          (avatars/*)
```

The application itself is a FastAPI service in ports-and-adapters layout
(details in the root `README.md`). Everything below is the platform around it.

---

## 2. Repository layout

```
.
├── app/                      Task 1 — the API (hexagonal architecture)
├── tests/                    unit + integration tests (AWS emulated by moto)
├── Dockerfile                Task 2 — multi-stage, non-root, distro-slim
├── docker-compose.yml        local stack: LocalStack + provisioner + API
├── infra/terraform/          Task 3 — DynamoDB, S3, IAM/IRSA, EKS roles
│   ├── dynamodb.tf s3.tf iam.tf
│   ├── variables.tf providers.tf locals.tf outputs.tf versions.tf
│   └── envs/                 localstack.tfvars · aws.tfvars.example
├── deploy/helm/prima-api/    Task 4 — the chart
│   ├── templates/            deployment, svc, hpa, pdb, sa, cm, secret,
│   │                         ingress, netpol, servicemonitor, helm test
│   └── values*.yaml          defaults · localstack · eks
├── .github/workflows/        Task 5 — ci.yml · cd.yml · security-nightly.yml
├── scripts/                  preflight · bootstrap_repo · minikube_up ·
│                             bootstrap_local · smoke
└── docs/ARCHITECTURE.md      this file
```

---

## 3. Task 2 — Container

Multi-stage build. The first stage compiles wheels into a virtualenv; the
runtime stage copies only that virtualenv, so no compiler or build cache ever
reaches the shipped image.

Hardening applied:

| Decision | Why |
| --- | --- |
| Dedicated `app` user (uid 1000) | A container escape should not start as uid 0 |
| `requirements.txt` copied on its own layer | Dependency layer stays cached until deps change |
| `PYTHONDONTWRITEBYTECODE`, `PYTHONUNBUFFERED` | No stray `.pyc` on a read-only FS; logs are not buffered away on crash |
| OCI labels with `VCS_REF` | `docker inspect` identifies the exact commit |
| `HEALTHCHECK` | Sensible behaviour under plain `docker run`; Kubernetes uses its own probes |
| `.dockerignore` excludes tests, `.git`, `.venv` | Smaller context, faster builds, no secrets from `.env` |

```bash
make build       # docker build with the git SHA baked in as a label
make up          # LocalStack + provisioner + API, wired together
make smoke       # end-to-end curl walkthrough
```

The `provisioner` service creates the table and bucket and then exits; the API
declares `depends_on: service_completed_successfully`, which removes the
classic "table not found" race on a cold start.

---

## 4. Task 3 — Infrastructure as Code

A single root module targets **both** LocalStack and real AWS. The only thing
that changes is the tfvars file, so there is no second copy of the code to
drift out of sync with the one you actually tested.

```hcl
# providers.tf — endpoints are redirected only when use_localstack = true
dynamic "endpoints" {
  for_each = var.use_localstack ? [1] : []
  content { dynamodb = var.localstack_endpoint  # ... }
}
```

### What it creates

| Resource | Notes |
| --- | --- |
| `aws_dynamodb_table.users` | `PAY_PER_REQUEST`, PK `email`, SSE on, PITR optional |
| `aws_s3_bucket.avatars` | Versioned, SSE-AES256, **public access fully blocked**, ownership `BucketOwnerEnforced` |
| Lifecycle rules | Abort stale multipart uploads; expire non-current avatar versions after 30 days |
| `aws_iam_policy.app` | Least privilege — see below |
| `aws_iam_role.app` | Assumed by the ServiceAccount via IRSA |
| `aws_iam_openid_connect_provider.eks` | Federation between the cluster and IAM |
| `aws_iam_role.eks_cluster` / `.eks_node` | The roles required to run an EKS cluster (opt-in) |
| `aws_iam_role.github_deploy` | GitHub Actions OIDC — deployments with no static keys (opt-in) |

### Least privilege, concretely

The application policy grants **only the five DynamoDB verbs the code calls**,
on that one table ARN — no `DeleteItem`, no `UpdateItem`, no wildcard. On S3 it
is scoped to the `avatars/*` prefix, and `ListBucket` carries an `s3:prefix`
condition so it cannot be used to enumerate the rest of the bucket.

### IRSA — how it authenticates against EKS

1. The cluster's OIDC issuer is registered as an IAM identity provider.
2. The role's trust policy accepts `sts:AssumeRoleWithWebIdentity` **only** when
   `sub == system:serviceaccount:prima:prima-api` and `aud == sts.amazonaws.com`.
   Both conditions matter: `sub` pins the exact ServiceAccount; `aud` stops a
   token minted for another audience from being replayed.
3. The ServiceAccount carries `eks.amazonaws.com/role-arn`; the EKS webhook sees
   it and projects a signed token into the pod.
4. boto3 picks the token up automatically — **no credentials exist anywhere in
   the cluster**, and they rotate themselves.

Because LocalStack CE does not implement EKS, `enable_irsa` defaults to `false`
there: the role, its policy and every output are created identically, only the
trust statement falls back to account-root. The AWS path is a tfvars flip, not a
code change.

```bash
make tf-plan     # plan against LocalStack
make tf-apply    # create table + bucket + IAM role
make tf-output   # names and ARNs, ready to feed into Helm
```

Terraform hands its outputs to Helm directly, with no copy-paste:

```bash
terraform -chdir=infra/terraform output -raw helm_values > values.generated.yaml
helm upgrade --install prima-api deploy/helm/prima-api -f values.generated.yaml
```

---

## 5. Task 4 — Helm chart

### Availability and reliability

| Concern | Mechanism |
| --- | --- |
| Autoscaling | HPA v2 on CPU **and** memory, 2→10 replicas, asymmetric `behavior`: scale out fast (30 s window), scale in slowly (300 s) to avoid flapping |
| Zero-downtime rollout | `maxUnavailable: 0`, `maxSurge: 1` — capacity never dips during a deploy |
| Voluntary disruptions | PodDisruptionBudget `minAvailable: 1` — a node drain can never take the service to zero |
| Zone failure | `topologySpreadConstraints` on `topology.kubernetes.io/zone` |
| Graceful shutdown | `preStop: sleep 5` + `terminationGracePeriodSeconds: 30`, so endpoints are withdrawn from every kube-proxy before the process stops accepting connections |
| Config changes | `checksum/config` annotation rolls the pods when the ConfigMap changes — otherwise an edit silently leaves the old values running |
| Replica count | Omitted from the Deployment when the HPA is enabled, so `helm upgrade` cannot reset the autoscaler's decision |

### Health probes — three, not one

```
startupProbe   /health/live    up to 60 s of grace for a cold start
livenessProbe  /health/live    never touches AWS  → a DynamoDB blip cannot
                               cause a cluster-wide restart storm
readinessProbe /health/ready   checks table + bucket → a broken pod is pulled
                               out of the Service instead of failing requests
```

This split is the single most important reliability decision in the chart: a
liveness probe that depends on a downstream service turns a partial outage into
a total one.

### Security

Compliant with the Pod Security Standard **restricted** profile:
`runAsNonRoot`, `readOnlyRootFilesystem` (with an in-memory `emptyDir` for
`/tmp`), `allowPrivilegeEscalation: false`, all capabilities dropped,
`seccompProfile: RuntimeDefault`, and the ServiceAccount token not mounted
(the app never calls the Kubernetes API).

The optional NetworkPolicy is default-deny with an explicit egress allow-list
(DNS + 443), so a compromised pod cannot exfiltrate data to an arbitrary host.

`_helpers.tpl` fails the render outright if IRSA and static credentials are both
configured — a misconfiguration that would otherwise only show up at runtime.

### Verifying a release

`helm test` ships with the chart: a curl pod that checks liveness, readiness
(which proves DynamoDB and S3 are reachable *from inside the pod*, IRSA
included) and that `GET /users` returns a JSON array.

---

## 6. Task 5 — CI/CD

Two workflows, deliberately separated: **CI proves an artifact is good, CD
promotes it.** CD never rebuilds from source — it re-tags the digest CI already
tested, so what runs in production is byte-for-byte what passed the gate.

### `ci.yml` — on every push and PR

| Job | What it does |
| --- | --- |
| `quality` | ruff (lint + format), mypy strict, pytest with coverage |
| `security` | gitleaks (secrets), Trivy fs (vulns + misconfig + secrets), hadolint — results uploaded as SARIF to the Security tab |
| `iac` | `terraform fmt/validate`, Checkov, and a **real plan against a LocalStack service container** — catches provider mistakes a `validate` waves through |
| `helm` | `helm lint --strict` on all three overlays, kubeconform against the K8s schema, Trivy config policy scan on the *rendered* manifests |
| `image` | buildx + GHCR, SBOM and SLSA provenance, Trivy image scan blocking on HIGH/CRITICAL, cosign **keyless** signature |
| `smoke` | Boots the entire compose stack and runs the end-to-end script |

Cross-cutting choices: `permissions` least-privilege at workflow level and
widened per job; `concurrency` cancels superseded runs; GHCR login is skipped on
pull requests so a fork can never obtain a push token; **no AWS credentials
exist anywhere** — moto covers the tests, LocalStack the plan.

### `cd.yml` — on a `v*.*.*` tag

Publishes the image and the chart (as an OCI artifact), creates the GitHub
release, then deploys with `helm upgrade --atomic --wait`, which rolls back
automatically if the new pods never become ready, and finishes with `helm test`.
Deployment credentials come from **GitHub OIDC → IAM role assumption**, so there
are no long-lived AWS keys in the repository.

The deploy job is gated behind the repository variable `DEPLOY_ENABLED`
(default `false`) and a protected `production` environment, because the brief
says explicitly not to create a real EKS cluster.

### `security-nightly.yml`

A green pipeline yesterday says nothing about a CVE published today, so the
released image is re-scanned on a schedule.

---

## 7. Running it — from a clean Ubuntu

### Prerequisites

```bash
./scripts/preflight.sh
```

Checks every tool and prints the exact install command for whatever is missing.
It never installs anything itself. Required: `python3`, `docker`, `git`,
`terraform`, `aws`, `kubectl`, `helm`, `minikube`. Optional: `gh`, `jq`,
`trivy`.

After installing Docker, log out and back in (or `newgrp docker`) so your user
picks up the `docker` group.

### Path A — application only (fastest)

```bash
make install     # virtualenv + dev dependencies
make test        # ~25 tests, no AWS account needed
make up          # LocalStack + API on http://localhost:8000/docs
make smoke
make down
```

### Path B — infrastructure with Terraform

```bash
docker compose up -d localstack
make tf-apply    # DynamoDB + S3 + IAM role inside LocalStack
make tf-output

aws --endpoint-url http://localhost:4566 dynamodb scan --table-name users
aws --endpoint-url http://localhost:4566 s3 ls s3://prima-tech-challenge/avatars/
```

### Path C — full Kubernetes deployment

```bash
make k8s-up      # minikube + LocalStack + Terraform + image + Helm + helm test
kubectl get all -n prima
kubectl port-forward -n prima svc/prima-api 8000:80
./scripts/smoke.sh http://localhost:8000
make k8s-down
```

`scripts/minikube_up.sh` handles the network detail the brief warns about:
LocalStack is started with `GATEWAY_LISTEN=0.0.0.0:4566` (the default loopback
binding is unreachable from inside the cluster), and the script resolves
`host.minikube.internal`, falling back to the node's default gateway on drivers
where that alias does not exist.

### Path D — publish to GitHub

```bash
gh auth login
./scripts/bootstrap_repo.sh prima-tech-challenge
```

Initialises git, rewrites the `OWNER` placeholders in the chart to your actual
GitHub account, creates the repository, pushes, sets the repository variables
and attempts to enable branch protection on `main`.

---

## 8. Known limits and next steps

* **`GET /users` uses `Scan`**, which is O(table). Fine at this scale and already
  paginated, but at real volume the listing belongs on a GSI with a bucketed
  partition key, or on a read projection.
* **Avatars are served from S3 directly.** In production: CloudFront with an
  Origin Access Control (the bucket already blocks public access), or presigned
  URLs. For large files, a presigned POST so images never transit the API.
* **No authentication.** `POST /user` is the expensive, abusable endpoint and
  would need JWT/Cognito plus per-IP rate limiting.
* **No metrics endpoint yet.** The chart has the `ServiceMonitor` ready; the app
  needs `/metrics` and OpenTelemetry traces spanning API → DynamoDB → S3.
* **GitHub Actions are pinned to tags, not SHAs.** Dependabot keeps them fresh;
  pinning to digests is the stricter supply-chain posture.
