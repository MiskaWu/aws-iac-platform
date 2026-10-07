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
    bucket       = "tofu-state-123456789012-ap-northeast-1"
    key          = "infra/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Stack     = "infra"
    }
  }
}
