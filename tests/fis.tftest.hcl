# Chaos as code: the FIS role trusts only FIS from this account, can interrupt
# only Spot nodes of pool general of this cluster, and the template hits one.
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
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:123456789012:test", url = "https://sqs.eu-west-1.amazonaws.com/123456789012/test" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/eks-llm-boundary"
  cluster_name             = "test"
  kubernetes_version       = "1.36"
  subnet_ids               = ["subnet-a", "subnet-b"]
  public_access_cidrs      = ["203.0.113.0/24"]
}

run "fis_off_by_default_on_free_plan" {
  command = apply
  module { source = "./modules/eks" }
  assert {
    condition     = length(aws_fis_experiment_template.spot_interruption) == 0 && length(aws_iam_role.fis) == 0 && length(aws_iam_role_policy.fis) == 0
    error_message = "FIS must be off by default: a Free Plan account cannot create the template"
  }
}

run "fis_spot_interruption_is_scoped" {
  command = apply
  module { source = "./modules/eks" }
  variables {
    fis_enabled = true
  }
  assert {
    condition = (jsondecode(aws_iam_role.fis[0].assume_role_policy).Statement[0].Principal == { Service = "fis.amazonaws.com" }
    && jsondecode(aws_iam_role.fis[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012")
    error_message = "the FIS role must trust only FIS, from this account"
  }
  assert {
    condition     = aws_iam_role.fis[0].permissions_boundary == "arn:aws:iam::123456789012:policy/eks-llm-boundary"
    error_message = "the FIS role must carry the boundary"
  }
  assert {
    condition = (jsondecode(aws_iam_role_policy.fis[0].policy).Statement[1].Action == "ec2:SendSpotInstanceInterruptions"
      && jsondecode(aws_iam_role_policy.fis[0].policy).Statement[1].Condition.StringEquals["aws:ResourceTag/karpenter.sh/nodepool"] == "general"
    && jsondecode(aws_iam_role_policy.fis[0].policy).Statement[1].Condition.StringEquals["aws:ResourceTag/eks:eks-cluster-name"] == "test")
    error_message = "the FIS role may interrupt only Spot nodes of pool general of this cluster"
  }
  assert {
    condition = (one(aws_fis_experiment_template.spot_interruption[0].target).selection_mode == "COUNT(1)"
      && one(aws_fis_experiment_template.spot_interruption[0].target).resource_type == "aws:ec2:spot-instance"
    && one(aws_fis_experiment_template.spot_interruption[0].action).action_id == "aws:ec2:send-spot-instance-interruptions")
    error_message = "the template must send a Spot interruption to exactly one Spot instance"
  }
}
