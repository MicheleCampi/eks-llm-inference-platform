# Every resource of a live session carries Session = its BUDGET entry
# (providers.tf default_tags), so Cost Explorer splits two sessions of the
# same day. A malformed value fails the plan.
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
}

run "session_in_default_tags" {
  command = plan
  variables { session = "A-025" }
  assert {
    condition     = local.tags["Session"] == "A-025" && local.tags["Project"] == "eks-llm-inference-platform"
    error_message = "default_tags must carry Session = the BUDGET entry and Project"
  }
}

run "rejects_free_text" {
  command = plan
  variables { session = "game day" }
  expect_failures = [var.session]
}

run "rejects_missing_entry_number" {
  command = plan
  variables { session = "A-" }
  expect_failures = [var.session]
}
