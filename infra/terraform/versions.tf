# Pinned toolchain: an IaC run must be reproducible months from now.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # Remote state is intentionally left out of the default flow so the challenge
  # can be evaluated with zero pre-existing AWS resources. See backend.tf.example.
}
