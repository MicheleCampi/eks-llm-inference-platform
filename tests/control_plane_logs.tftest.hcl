# Control-plane audit logging (docs/compliance-map.md CC7.2, A.8.15): on by
# default with a Terraform-owned log group and a bounded retention, so destroy
# removes it and nothing is kept forever.
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

run "audit_logging_on_by_default" {
  command = plan
  assert {
    condition     = toset(module.eks.control_plane_log_types) == toset(["api", "audit", "authenticator"])
    error_message = "api, audit and authenticator logs must be on by default"
  }
  assert {
    condition     = module.eks.control_plane_log_group == "/aws/eks/llm-inference/cluster"
    error_message = "the log group must be the one EKS writes to, owned by Terraform"
  }
  assert {
    condition     = module.eks.control_plane_log_retention_days == 7
    error_message = "retention must be bounded (7 days for live sessions)"
  }
}
