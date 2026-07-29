#!/usr/bin/env bash
# End-to-end local deployment: minikube + LocalStack + Terraform + Helm.
#
#   ./scripts/minikube_up.sh
#
# LocalStack runs on the host (bound to 0.0.0.0 so pods can reach it) and
# Terraform provisions the table, bucket and IAM role against it — exactly the
# same code path a real AWS run would take.
set -euo pipefail

NAMESPACE="${NAMESPACE:-prima}"
RELEASE="${RELEASE:-prima-api}"
IMAGE="${IMAGE:-prima-tech-challenge:local}"
CHART="deploy/helm/prima-api"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

step "1/7 Starting minikube"
if ! minikube status >/dev/null 2>&1; then
  minikube start --cpus=2 --memory=3g --driver=docker
fi
# The HPA needs a metrics source; without this addon it reports <unknown>.
minikube addons enable metrics-server >/dev/null

step "2/7 Starting LocalStack on the host (0.0.0.0:4566)"
# GATEWAY_LISTEN is what makes LocalStack reachable from inside the cluster;
# the default binding of 127.0.0.1 is not.
GATEWAY_LISTEN=0.0.0.0:4566 docker compose up -d localstack
for i in $(seq 1 60); do
  curl -fs http://localhost:4566/_localstack/health >/dev/null 2>&1 && break
  sleep 1
done

step "3/7 Provisioning AWS resources with Terraform"
terraform -chdir=infra/terraform init -input=false >/dev/null
terraform -chdir=infra/terraform apply -auto-approve -input=false \
  -var-file=envs/localstack.tfvars
TABLE="$(terraform -chdir=infra/terraform output -raw dynamodb_table_name)"
BUCKET="$(terraform -chdir=infra/terraform output -raw s3_bucket_name)"
echo "    table=${TABLE} bucket=${BUCKET}"

step "4/7 Building the image inside minikube's Docker daemon"
# Building in-cluster avoids needing a registry and makes imagePullPolicy:Never
# work out of the box.
eval "$(minikube docker-env)"
docker build -t "${IMAGE}" .
eval "$(minikube docker-env -u)"

step "5/7 Resolving the host address reachable from the pods"
# host.minikube.internal is the documented alias, but it does not exist on
# every driver; fall back to the gateway IP seen from inside the node.
if minikube ssh -- getent hosts host.minikube.internal >/dev/null 2>&1; then
  HOST_ADDR="host.minikube.internal"
else
  HOST_ADDR="$(minikube ssh -- ip route | awk '/default/ {print $3}' | tr -d '\r')"
fi
ENDPOINT="http://${HOST_ADDR}:4566"
echo "    LocalStack endpoint for pods: ${ENDPOINT}"

step "6/7 Deploying the Helm chart"
helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" --create-namespace \
  -f "${CHART}/values-localstack.yaml" \
  --set image.tag=local \
  --set aws.endpointUrl="${ENDPOINT}" \
  --set aws.dynamodbTable="${TABLE}" \
  --set aws.s3Bucket="${BUCKET}" \
  --wait --timeout 5m

step "7/7 Verifying the deployment"
kubectl rollout status "deploy/${RELEASE}" -n "${NAMESPACE}" --timeout=120s
helm test "${RELEASE}" -n "${NAMESPACE}"

cat <<MSG

Deployment is live.

  kubectl get all -n ${NAMESPACE}
  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE} 8000:80
  ./scripts/smoke.sh http://localhost:8000

Tear everything down with: make k8s-down
MSG
