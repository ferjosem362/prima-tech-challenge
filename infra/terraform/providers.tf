# ---------------------------------------------------------------------------
# Provider configuration.
#
# A single root module targets both LocalStack and real AWS: the only thing
# that changes is a tfvars file. No duplicated code, no drift between the
# environment you test and the environment you ship.
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  # LocalStack accepts any credentials; real AWS uses the standard chain.
  access_key = var.use_localstack ? "test" : null
  secret_key = var.use_localstack ? "test" : null

  # These checks talk to the real AWS metadata/STS services and would hang or
  # fail against LocalStack.
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack
  # LocalStack's S3 does not do virtual-host style addressing on localhost.
  s3_use_path_style = var.use_localstack

  # Only the services this stack actually uses are redirected.
  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      dynamodb = var.localstack_endpoint
      s3       = var.localstack_endpoint
      iam      = var.localstack_endpoint
      sts      = var.localstack_endpoint
    }
  }

  # Tag everything, everywhere, automatically: cost allocation and cleanup
  # both depend on it.
  default_tags {
    tags = local.common_tags
  }
}
