# Karpenter finds node subnets by karpenter.sh/discovery. One owner only: the vpc
# module (live attempt 2: a second owner, aws_ec2_tag, made every plan remove it).
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

run "every_private_subnet_is_discoverable" {
  command = plan
  assert {
    condition     = length(module.vpc.private_subnet_discovery_tags) == 2 && alltrue([for v in module.vpc.private_subnet_discovery_tags : v == "llm-inference"])
    error_message = "every private subnet must carry karpenter.sh/discovery = cluster name"
  }
}
