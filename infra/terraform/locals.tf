# Account id is only queried against real AWS; LocalStack always reports the
# well-known dummy account, so we avoid an unnecessary STS round-trip.
data "aws_caller_identity" "current" {
  count = var.use_localstack ? 0 : 1
}

data "aws_partition" "current" {}

locals {
  account_id = var.use_localstack ? "000000000000" : data.aws_caller_identity.current[0].account_id
  partition  = data.aws_partition.current.partition

  table_name = coalesce(var.dynamodb_table_name, "${var.name_prefix}-users")

  bucket_base = coalesce(var.s3_bucket_name, "${var.name_prefix}-avatars")
  bucket_name = var.s3_bucket_suffix_account_id ? "${local.bucket_base}-${local.account_id}" : local.bucket_base

  # Strip the scheme: IAM condition keys use the bare host/path of the issuer.
  oidc_host = replace(var.eks_oidc_issuer_url, "https://", "")

  # "system:serviceaccount:<namespace>:<name>" is the subject EKS puts in the
  # projected token; matching it exactly is what makes IRSA least-privilege.
  irsa_subject = "system:serviceaccount:${var.kubernetes_namespace}:${var.kubernetes_service_account}"

  # Scoping DescribeCluster to an ARN instead of "*" is what turns this from a
  # blanket grant into a least-privilege one. A wildcard cluster segment still
  # confines the role to EKS in this account and region.
  eks_cluster_arn = format(
    "arn:%s:eks:%s:%s:cluster/%s",
    local.partition,
    var.aws_region,
    local.account_id,
    var.eks_cluster_name != "" ? var.eks_cluster_name : "*",
  )

  common_tags = merge(
    {
      Project     = var.name_prefix
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "user-api"
    },
    var.tags,
  )
}
