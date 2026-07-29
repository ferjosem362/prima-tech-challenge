# ---------------------------------------------------------------------------
# Object storage: avatar images.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "avatars" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy_bucket

  tags = { Name = local.bucket_name }
}

# Explicit ownership controls: ACLs are disabled, access is granted by policy
# only. This is the modern S3 default and avoids the classic "public via ACL"
# footgun entirely.
resource "aws_s3_bucket_ownership_controls" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # Cuts KMS costs and latency dramatically when using a CMK; harmless here.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  versioning_configuration {
    # Versioning turns an accidental delete or overwrite into a recoverable
    # event; the lifecycle rule below stops old versions from piling up.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  # The bucket itself stays private. Avatars are meant to be served through
  # CloudFront with an Origin Access Control, or through presigned URLs —
  # never by making the bucket world-readable.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "avatars" {
  # Skipped against LocalStack CE. The AWS provider waits for a follow-up read
  # to confirm the configuration (eventual consistency), and LocalStack never
  # satisfies that check, so the apply hangs for the full 3-minute timeout and
  # then fails. The rules themselves are correct and do apply on real AWS.
  count = var.use_localstack ? 0 : 1

  bucket     = aws_s3_bucket.avatars.id
  depends_on = [aws_s3_bucket_versioning.avatars]

  # Safety net for the compensating delete in the API: if the process dies
  # between the S3 upload and the DynamoDB write, the orphan object is swept.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "expire-noncurrent-avatar-versions"
    status = "Enabled"

    filter {
      prefix = "${var.avatar_prefix}/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
