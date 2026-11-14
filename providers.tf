# One source for the cost allocation tags: provider default_tags and the
# budget filter (budget.tf). ci/check-cost-tags.py compares Project with the
# Karpenter EC2NodeClass.
locals {
  tags = {
    Project   = "eks-llm-inference-platform"
    ManagedBy = "terraform"
    Owner     = "michele"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
