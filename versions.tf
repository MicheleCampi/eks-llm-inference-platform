terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    # Bucket created out-of-band (bootstrap): see README.
    bucket       = "michele-tfstate-eks-llm"
    key          = "eks-llm-inference-platform/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
