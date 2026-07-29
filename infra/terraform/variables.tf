# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "prima-tech-challenge"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens (3-40 chars)."
  }
}

variable "environment" {
  description = "Logical environment (local, dev, prod...). Used in tags."
  type        = string
  default     = "local"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Extra tags merged into the default ones."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# LocalStack
# ---------------------------------------------------------------------------
variable "use_localstack" {
  description = "Redirect every AWS endpoint to LocalStack and relax credential checks."
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint."
  type        = string
  default     = "http://localhost:4566"
}

# ---------------------------------------------------------------------------
# Application resources
# ---------------------------------------------------------------------------
variable "dynamodb_table_name" {
  description = "Table name. Defaults to <name_prefix>-users."
  type        = string
  default     = ""
}

variable "s3_bucket_name" {
  description = "Bucket name. Defaults to <name_prefix>-avatars."
  type        = string
  default     = ""
}

variable "s3_bucket_suffix_account_id" {
  description = "Append the account id to the bucket name (S3 names are globally unique)."
  type        = bool
  default     = false
}

variable "avatar_prefix" {
  description = "Key prefix under which avatars are stored. Scopes the IAM policy."
  type        = string
  default     = "avatars"
}

variable "force_destroy_bucket" {
  description = "Allow `terraform destroy` to delete a non-empty bucket. Never true in prod."
  type        = bool
  default     = true
}

variable "enable_point_in_time_recovery" {
  description = "DynamoDB PITR. Not emulated by LocalStack CE, so off by default."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Kubernetes / IRSA
# ---------------------------------------------------------------------------
variable "kubernetes_namespace" {
  description = "Namespace the application runs in."
  type        = string
  default     = "prima"
}

variable "kubernetes_service_account" {
  description = "ServiceAccount the application pods use."
  type        = string
  default     = "prima-api"
}

variable "enable_irsa" {
  description = <<-EOT
    Create the IAM Role for Service Accounts (IRSA) trust relationship.
    Requires a real EKS cluster's OIDC issuer, so it stays off under LocalStack CE
    (which does not implement EKS). The role and its policies are still created:
    only the federated trust statement is swapped for a placeholder.
  EOT
  type        = bool
  default     = false
}

variable "eks_oidc_issuer_url" {
  description = "EKS OIDC issuer URL, e.g. https://oidc.eks.eu-west-1.amazonaws.com/id/ABC123."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Create the IAM OIDC provider for the cluster (false if it already exists)."
  type        = bool
  default     = true
}

variable "enable_eks_platform_roles" {
  description = "Create the cluster/node roles needed to operate an EKS cluster."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# CI/CD (GitHub Actions OIDC — keyless deployments)
# ---------------------------------------------------------------------------
variable "enable_github_oidc" {
  description = "Create a deployment role GitHub Actions can assume without static keys."
  type        = bool
  default     = false
}

variable "eks_cluster_name" {
  description = "Cluster the GitHub deployment role may describe. Empty = any cluster in the account."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "owner/repo allowed to assume the deployment role."
  type        = string
  default     = ""
}
