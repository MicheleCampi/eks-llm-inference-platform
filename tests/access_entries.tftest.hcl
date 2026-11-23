# Human cluster admins are code: access entry + cluster-scoped admin policy,
# no wildcard principal (live attempt 2: only the pipeline role could reach the API).
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
}

variables {
  public_access_cidrs = ["203.0.113.0/24"]
  session             = "A-000"
}

run "admin_is_cluster_scoped" {
  command = plan
  assert {
    condition     = length(module.eks.cluster_admins) == 1 && alltrue([for k, v in module.eks.cluster_admins : endswith(k, ":user/michele-cli") && v.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"])
    error_message = "michele-cli must get AmazonEKSClusterAdminPolicy through an access entry"
  }
  assert {
    condition     = length(module.eks.cluster_admins) == 1 && alltrue([for v in values(module.eks.cluster_admins) : v.scope == "cluster"])
    error_message = "the admin access policy must be cluster-scoped"
  }
}

run "rejects_wildcard_user" {
  command = plan
  variables { cluster_admin_iam_users = ["*"] }
  expect_failures = [var.cluster_admin_iam_users]
}
