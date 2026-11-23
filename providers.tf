# One source for the cost allocation tags: provider default_tags and the
# budget filter (budget.tf). ci/check-cost-tags.py compares Project with the
# Karpenter EC2NodeClass, and checks that the Karpenter nodes get Session too
# (gitops/apps/karpenter-nodes.yaml, from the Argo CD cluster label).
# Session is the BUDGET entry of the live session (A-025, ...): Cost Explorer
# grouped by tag Session splits the cost of two sessions on the same day,
# which daily granularity alone cannot (22/11: A-021 to A-024 estimated).
# Project and Session are activated as cost allocation tags in
# bootstrap/ci-identity, which a destroy never touches.
locals {
  tags = {
    Project   = "eks-llm-inference-platform"
    Session   = var.session
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
