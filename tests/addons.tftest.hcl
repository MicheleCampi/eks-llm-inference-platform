# Node image and add-ons: every version pinned, metrics-server HA declared,
# so a change of AWS default cannot alter the cluster silently.
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

run "pinned_and_ha" {
  command = apply
  module { source = "./modules/eks" }

  assert {
    condition = (aws_eks_node_group.default.ami_type == "AL2023_x86_64_STANDARD"
    && aws_eks_node_group.default.release_version == "1.36.5-20261107")
    error_message = "node group image must be pinned to the Karpenter AL2023 release"
  }

  assert {
    condition     = aws_eks_addon.pod_identity_agent.addon_version == "v1.4.1-eksbuild.3"
    error_message = "eks-pod-identity-agent must be pinned"
  }

  assert {
    condition = (aws_eks_addon.metrics_server.addon_version == "v0.9.1-eksbuild.1"
      && jsondecode(aws_eks_addon.metrics_server.configuration_values).replicas == 2
      && jsondecode(aws_eks_addon.metrics_server.configuration_values).podDisruptionBudget.enabled
    && jsondecode(aws_eks_addon.metrics_server.configuration_values).topologySpreadConstraints[0].topologyKey == "topology.kubernetes.io/zone")
    error_message = "metrics-server must be pinned, 2 replicas across zones, with a PDB"
  }

  assert {
    condition     = jsondecode(aws_eks_addon.metrics_server.configuration_values).resources.requests == { cpu = "100m", memory = "200Mi" }
    error_message = "metrics-server requests must be declared"
  }
}

run "node_cost_tags" {
  command = apply
  module {
    source = "./modules/eks"
  }
  assert {
    condition     = toset([for t in aws_launch_template.node.tag_specifications : t.resource_type]) == toset(["instance", "volume", "network-interface"])
    error_message = "node launch template must tag instances, volumes and ENIs for cost allocation"
  }
}
