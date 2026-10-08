terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket 與 region 要和 bootstrap 的輸出一致
  backend "s3" {
    bucket       = "tofu-state-123456789012-ap-east-2"
    key          = "infra/terraform.tfstate"
    region       = "ap-east-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-east-2"

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Stack     = "infra"
    }
  }
}
