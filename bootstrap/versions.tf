terraform {
  # use_lockfile（S3 原生鎖）需要 OpenTofu 1.10 以上
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Stack     = "bootstrap"
    }
  }
}
