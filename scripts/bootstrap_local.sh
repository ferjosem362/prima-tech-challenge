#!/bin/sh
# Idempotent provisioning of the local DynamoDB table and S3 bucket.
# Safe to re-run: existing resources are left untouched.
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
TABLE="${DYNAMODB_TABLE:-users}"
BUCKET="${S3_BUCKET:-prima-tech-challenge}"

echo "==> Provisioning against ${ENDPOINT}"

if aws --endpoint-url "${ENDPOINT}" dynamodb describe-table \
      --table-name "${TABLE}" >/dev/null 2>&1; then
  echo "    table '${TABLE}' already exists"
else
  echo "    creating table '${TABLE}' (PK: email)"
  aws --endpoint-url "${ENDPOINT}" dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=email,AttributeType=S \
    --key-schema AttributeName=email,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
fi

if aws --endpoint-url "${ENDPOINT}" s3api head-bucket \
      --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "    bucket '${BUCKET}' already exists"
else
  echo "    creating bucket '${BUCKET}'"
  aws --endpoint-url "${ENDPOINT}" s3api create-bucket --bucket "${BUCKET}" >/dev/null
fi

# Avatars must be readable by the browser that renders avatar_url. In real AWS
# the right answer is a CloudFront distribution with an Origin Access Control
# instead of a public bucket; this policy exists for local convenience only.
aws --endpoint-url "${ENDPOINT}" s3api put-bucket-policy --bucket "${BUCKET}" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"PublicReadAvatars\",
    \"Effect\": \"Allow\",
    \"Principal\": \"*\",
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::${BUCKET}/avatars/*\"
  }]
}" >/dev/null 2>&1 || echo "    (bucket policy skipped)"

echo "==> Done"
