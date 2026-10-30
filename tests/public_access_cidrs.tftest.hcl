# Mutation check for D2: the EKS public endpoint must never be open to the internet.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
}

run "rejects_empty_list" {
  command = plan
  variables { public_access_cidrs = [] }
  expect_failures = [var.public_access_cidrs]
}

run "rejects_open_internet" {
  command = plan
  variables { public_access_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.public_access_cidrs]
}

run "accepts_specific_cidr" {
  command = plan
  variables { public_access_cidrs = ["203.0.113.0/24"] }
  assert {
    condition     = length(var.public_access_cidrs) == 1 && contains(var.public_access_cidrs, "203.0.113.0/24")
    error_message = "a specific CIDR must pass validation"
  }
}
