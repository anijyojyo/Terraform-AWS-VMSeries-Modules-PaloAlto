terraform {
  required_version = ">= 0.12.29, < 1.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 3.15" # 3.15 because of https://github.com/hashicorp/terraform-provider-aws/issues/16131
    }
  }
}

provider "aws" {
  region = var.region
}