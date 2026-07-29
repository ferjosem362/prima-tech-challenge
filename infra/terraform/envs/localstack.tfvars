# LocalStack CE profile — the default, zero-cost path.
#   terraform apply -var-file=envs/localstack.tfvars
environment                 = "local"
aws_region                  = "us-east-1"
use_localstack              = true
localstack_endpoint         = "http://localhost:4566"
dynamodb_table_name         = "users"
s3_bucket_name              = "prima-tech-challenge"
force_destroy_bucket        = true

# EKS and PITR are not implemented by LocalStack CE.
enable_irsa                   = false
enable_eks_platform_roles     = false
enable_point_in_time_recovery = false
