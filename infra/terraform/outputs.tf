output "dynamodb_table_name" {
  description = "Name of the users table."
  value       = aws_dynamodb_table.users.name
}

output "s3_bucket_name" {
  description = "Name of the avatars bucket."
  value       = aws_s3_bucket.avatars.bucket
}

output "app_role_arn" {
  description = "IAM role the application ServiceAccount assumes."
  value       = aws_iam_role.app.arn
}

output "eks_cluster_role_arn" {
  description = "EKS control-plane role (null unless enable_eks_platform_roles)."
  value       = try(aws_iam_role.eks_cluster[0].arn, null)
}

output "eks_node_role_arn" {
  description = "EKS managed node group role (null unless enable_eks_platform_roles)."
  value       = try(aws_iam_role.eks_node[0].arn, null)
}

output "github_deploy_role_arn" {
  description = "Role GitHub Actions assumes to deploy (null unless enable_github_oidc)."
  value       = try(aws_iam_role.github_deploy[0].arn, null)
}

# Bridge between Terraform and Helm: instead of copying values by hand, render
# them and feed the file straight into `helm upgrade -f`.
#   terraform output -raw helm_values > ../../deploy/helm/values.generated.yaml
output "helm_values" {
  description = "Ready-to-use Helm values derived from the created infrastructure."
  value = yamlencode({
    serviceAccount = {
      name = var.kubernetes_service_account
      annotations = var.enable_irsa ? {
        "eks.amazonaws.com/role-arn" = aws_iam_role.app.arn
      } : {}
    }
    aws = {
      region        = var.aws_region
      dynamodbTable = aws_dynamodb_table.users.name
      s3Bucket      = aws_s3_bucket.avatars.bucket
    }
  })
}
