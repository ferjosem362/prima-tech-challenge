# ---------------------------------------------------------------------------
# Persistence: one item per user, partitioned by email.
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "users" {
  name = local.table_name

  # On-demand: no capacity planning for an unpredictable workload, and it costs
  # nothing while idle. Switch to PROVISIONED + autoscaling once the traffic
  # shape is known and steady.
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }

  # Only the key schema is declared: DynamoDB is schema-less for every other
  # attribute, which is exactly why `name` and `avatar_url` are absent here.

  server_side_encryption {
    enabled = true # AWS-owned key; set kms_key_arn for a CMK
  }

  dynamic "point_in_time_recovery" {
    for_each = var.enable_point_in_time_recovery ? [1] : []
    content {
      enabled = true
    }
  }

  # Guard against a fat-fingered `terraform destroy` outside local runs.
  deletion_protection_enabled = var.environment == "prod"

  lifecycle {
    # The table is the source of truth for user data: refuse to silently
    # replace it if someone changes an immutable attribute.
    prevent_destroy = false # set to true in prod overlays
  }

  tags = { Name = local.table_name }
}
