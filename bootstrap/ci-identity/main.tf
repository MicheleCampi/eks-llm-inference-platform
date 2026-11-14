# CI identity for terraform plan on pull requests: one-time, out of the cluster
# stack, so destroying the cluster never removes it. IAM is free.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "michele-tfstate-eks-llm"
    key          = "eks-llm-inference-platform/bootstrap/ci-identity.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Project   = "eks-llm-inference-platform"
      ManagedBy = "terraform"
      Owner     = "michele"
    }
  }
}

locals {
  state_bucket = "michele-tfstate-eks-llm"
  state_key    = "eks-llm-inference-platform/terraform.tfstate"
  # Immutable subject (owner and repo ids, read from the GitHub API on 14/11):
  # a repo deleted and recreated under the same name does not inherit trust.
  plan_subject = "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:pull_request"
}

# Shared GitHub OIDC provider, owned by aws-ecs-delivery-platform: read, not managed.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_partition" "current" {}

resource "aws_iam_role" "plan" {
  name                 = "eks-llm-ci-plan"
  description          = "terraform plan on pull requests of eks-llm-inference-platform"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.plan_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# State: read this stack's state, write only its lock file. The Deny statements
# win over ReadOnlyAccess, which otherwise reads every bucket (other projects'
# state included) and every secret.
resource "aws_iam_role_policy" "state" {
  name = "terraform-state-plan"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ListStateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket}" },
      { Sid = "ReadState", Effect = "Allow", Action = "s3:GetObject", Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket}/${local.state_key}" },
      { Sid = "WriteLockfileOnly", Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject"], Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket}/${local.state_key}.tflock" },
      { Sid = "DenyOtherObjects", Effect = "Deny", Action = "s3:GetObject", NotResource = ["arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket}/${local.state_key}", "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket}/${local.state_key}.tflock"] },
      { Sid = "DenySecretValues", Effect = "Deny", Action = "secretsmanager:GetSecretValue", Resource = "*" },
    ]
  })
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}
