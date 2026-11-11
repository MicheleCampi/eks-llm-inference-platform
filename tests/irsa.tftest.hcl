# S4: pods cannot reach the node role, and an IRSA role trusts exactly one service account.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = { identity = [{ oidc = [{ issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE" }] }] }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:123456789012:test", url = "https://sqs.eu-west-1.amazonaws.com/123456789012/test" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE" }
  }
}

variables {
  cluster_name        = "test"
  kubernetes_version  = "1.36"
  subnet_ids          = ["subnet-a", "subnet-b"]
  public_access_cidrs = ["203.0.113.0/24"]
}

run "nodes_block_imds_from_pods" {
  command = plan
  module { source = "./modules/eks" }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "nodes must require IMDSv2 with a hop limit of 1"
  }
  assert {
    condition     = length(aws_eks_node_group.default.launch_template) == 1
    error_message = "the node group must use the launch template"
  }
}

run "rejects_wildcard_service_account" {
  command = plan
  module { source = "./modules/eks" }
  variables { irsa_roles = { x = { namespace = "team-a", service_account = "*", policy_arns = [] } } }
  expect_failures = [var.irsa_roles]
}

run "rejects_wildcard_namespace" {
  command = plan
  module { source = "./modules/eks" }
  variables { irsa_roles = { x = { namespace = "*", service_account = "reader", policy_arns = [] } } }
  expect_failures = [var.irsa_roles]
}

run "trust_is_one_service_account" {
  command = apply
  module { source = "./modules/eks" }
  variables {
    irsa_roles = { reader = { namespace = "team-a", service_account = "s3-reader", policy_arns = ["arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"] } }
  }
  assert {
    condition = jsondecode(aws_iam_role.irsa["reader"].assume_role_policy).Statement[0].Condition.StringEquals == {
      "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE:sub" = "system:serviceaccount:team-a:s3-reader"
      "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE:aud" = "sts.amazonaws.com"
    }
    error_message = "the trust must match exactly one service account and the STS audience"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.irsa) == 1
    error_message = "one policy attached"
  }
}
