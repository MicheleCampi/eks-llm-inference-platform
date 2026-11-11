# Karpenter: the controller role trusts one service account, every official
# policy is rendered and attached, and interruptions reach the queue over TLS only.
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
  cluster_name        = "test"
  kubernetes_version  = "1.36"
  subnet_ids          = ["subnet-a", "subnet-b"]
  public_access_cidrs = ["203.0.113.0/24"]
}

run "karpenter_wiring" {
  command = apply
  module { source = "./modules/eks" }
  assert {
    condition = (jsondecode(aws_iam_role.karpenter.assume_role_policy).Statement[0].Principal == { Service = "pods.eks.amazonaws.com" }
      && aws_eks_pod_identity_association.karpenter.namespace == "kube-system"
      && aws_eks_pod_identity_association.karpenter.service_account == "karpenter"
    && aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent")
    error_message = "the controller role must trust only kube-system/karpenter"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.karpenter) == 6
    error_message = "all 6 official controller policies must be attached"
  }
  assert {
    condition     = alltrue([for p in aws_iam_policy.karpenter : !strcontains(p.policy, "$${") && strcontains(p.policy, "arn:aws:")])
    error_message = "every policy must be fully rendered"
  }
  assert {
    condition     = strcontains(aws_iam_policy.karpenter["InterruptionPolicy"].policy, "arn:aws:sqs:eu-west-1:123456789012:test")
    error_message = "the interruption policy must name the queue"
  }
  assert {
    condition     = jsondecode(aws_sqs_queue_policy.karpenter.policy).Statement[1].Condition.Bool["aws:SecureTransport"] == false && jsondecode(aws_sqs_queue_policy.karpenter.policy).Statement[1].Effect == "Deny"
    error_message = "the queue must deny non-TLS access"
  }
  assert {
    condition     = length(aws_cloudwatch_event_target.karpenter) == 5 && alltrue([for t in aws_cloudwatch_event_target.karpenter : t.arn == aws_sqs_queue.karpenter.arn])
    error_message = "all 5 interruption rules must target the queue"
  }
  assert {
    condition     = length(aws_ec2_tag.karpenter_subnet) == 2
    error_message = "every node subnet must carry the discovery tag"
  }
}
