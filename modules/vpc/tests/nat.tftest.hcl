# Plan-only tests with a mocked provider: no AWS credentials, no cost.
mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  override_data {
    target = data.aws_region.this
    values = { region = "eu-west-1" }
  }
}

variables {
  name     = "test"
  vpc_cidr = "10.0.0.0/16"
}

run "single_shares_one_nat" {
  command = plan
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_egress) == 2
    error_message = "single (default) must create 1 NAT shared by 2 private route tables"
  }
}

run "private_subnets_get_no_public_ip" {
  command = plan
  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch != true])
    error_message = "private subnets must not assign public IPs"
  }
}

run "per_az_one_nat_per_az" {
  command = plan
  variables { nat_mode = "per_az" }
  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "per_az must create one NAT per AZ"
  }
}

run "none_has_no_egress" {
  command = plan
  variables { nat_mode = "none" }
  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_egress) == 0
    error_message = "none must create no NAT and no egress route"
  }
}

run "rejects_unknown_nat_mode" {
  command = plan
  variables { nat_mode = "double" }
  expect_failures = [var.nat_mode]
}
