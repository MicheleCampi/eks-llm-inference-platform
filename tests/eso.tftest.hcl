# ESO: the role trusts one service account and can only read the Grafana
# Cloud secret, which Terraform creates empty and deletes without recovery.
mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:test/grafana-cloud-remote-write-AbCdEf" }
  }
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

run "eso_wiring" {
  command = apply
  module { source = "./modules/eks" }
  assert {
    condition = (jsondecode(aws_iam_role.eso.assume_role_policy).Statement[0].Principal == { Service = "pods.eks.amazonaws.com" }
      && aws_eks_pod_identity_association.eso.namespace == "external-secrets"
    && aws_eks_pod_identity_association.eso.service_account == "external-secrets")
    error_message = "the ESO role must trust only external-secrets/external-secrets"
  }
  assert {
    condition = (jsondecode(aws_iam_role_policy.eso.policy).Statement[0].Resource == aws_secretsmanager_secret.grafana_cloud.arn
      && toset(jsondecode(aws_iam_role_policy.eso.policy).Statement[0].Action) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    && length(jsondecode(aws_iam_role_policy.eso.policy).Statement) == 1)
    error_message = "ESO may only read the one Grafana Cloud secret"
  }
  assert {
    condition     = aws_secretsmanager_secret.grafana_cloud.recovery_window_in_days == 0 && aws_secretsmanager_secret.grafana_cloud.name == "test/grafana-cloud-remote-write"
    error_message = "the secret must be named per cluster and deleted without recovery window"
  }
}
