#!/usr/bin/env bash
# Creates the GitHub repository from scratch and pushes this project into it.
#
#   ./scripts/bootstrap_repo.sh <repo-name> [--public]
#
# Prerequisites: gh (authenticated with `gh auth login`) and git.
set -euo pipefail

REPO_NAME="${1:-prima-tech-challenge}"
VISIBILITY="--private"
[ "${2:-}" = "--public" ] && VISIBILITY="--public"

command -v gh  >/dev/null || { echo "gh CLI not found. See scripts/preflight.sh"; exit 1; }
command -v git >/dev/null || { echo "git not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first."; exit 1; }

OWNER="$(gh api user --jq .login)"
FULL="${OWNER}/${REPO_NAME}"
echo "==> Target repository: ${FULL} (${VISIBILITY#--})"

# --- 1. Local repository ---------------------------------------------------
if [ ! -d .git ]; then
  git init -b main
  echo "    initialised a fresh git repository"
fi

# The image repository in the chart must match the real GitHub owner, otherwise
# the first deployment pulls from a namespace that does not exist.
echo "==> Pointing the chart at ghcr.io/${FULL}"
sed -i "s#ghcr.io/OWNER/prima-tech-challenge#ghcr.io/${FULL}#g" \
  deploy/helm/prima-api/values.yaml
sed -i "s#https://github.com/OWNER/prima-tech-challenge#https://github.com/${FULL}#g" \
  deploy/helm/prima-api/Chart.yaml
# README badges point at the Actions workflows of the real repository.
sed -i "s#OWNER/prima-tech-challenge#${FULL}#g" README.md

git add -A
git commit -m "feat: user API with DynamoDB and S3, IaC, Helm chart and CI/CD" --quiet || \
  echo "    nothing new to commit"

# --- 2. Remote repository --------------------------------------------------
if gh repo view "${FULL}" >/dev/null 2>&1; then
  echo "==> Repository already exists, reusing it"
  git remote get-url origin >/dev/null 2>&1 || \
    git remote add origin "https://github.com/${FULL}.git"
  git push -u origin main
else
  gh repo create "${FULL}" ${VISIBILITY} \
    --source=. --remote=origin --push \
    --description "User API on FastAPI + DynamoDB + S3, deployed to Kubernetes with Helm"
fi

# --- 3. Repository configuration -------------------------------------------
echo "==> Configuring the repository"
# CD is skipped unless this is flipped to true and a cluster actually exists.
gh variable set DEPLOY_ENABLED --body "false" --repo "${FULL}" 2>/dev/null || true
gh variable set AWS_REGION     --body "us-east-1" --repo "${FULL}" 2>/dev/null || true
gh variable set K8S_NAMESPACE  --body "prima"     --repo "${FULL}" 2>/dev/null || true

# Branch protection needs a paid plan on private repos; failing here is fine.
gh api -X PUT "repos/${FULL}/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  -f "required_status_checks[strict]=true" \
  -f "required_status_checks[contexts][]=Lint, types & tests" \
  -F "enforce_admins=false" \
  -F "required_pull_request_reviews[required_approving_review_count]=1" \
  -F "restrictions=null" >/dev/null 2>&1 \
  && echo "    branch protection enabled on main" \
  || echo "    branch protection skipped (needs a plan that supports it)"

echo
echo "==> Done: https://github.com/${FULL}"
echo "    Actions: https://github.com/${FULL}/actions"
echo "    Next:    make up   (local stack)   |   make k8s-up   (minikube)"
