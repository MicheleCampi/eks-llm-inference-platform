# The plan role trusts only this repo's pull requests, by immutable subject,
# reads only this stack's state and writes only its lock file.
mock_provider "aws" {
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

run "trust_is_this_repo_pull_requests" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:pull_request"
    error_message = "trust must be this repo's pull requests, immutable subject"
  }
  assert {
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "audience must be sts.amazonaws.com"
  }
}

run "no_wildcard_subject" {
  command = plan
  assert {
    condition     = !strcontains(aws_iam_role.plan.assume_role_policy, "*") && length(jsondecode(aws_iam_role.plan.assume_role_policy).Statement) == 1
    error_message = "trust policy must have one statement and no wildcard"
  }
}

run "denies_win_over_read_only" {
  command = plan
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.state.policy).Statement : s if s.Effect == "Deny"]) == 2
    error_message = "Deny on other objects and on secret values expected"
  }
}

run "writes_only_the_lock" {
  command = plan
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.state.policy).Statement :
    endswith(s.Resource, ".tflock") if s.Effect == "Allow" && contains(flatten([s.Action]), "s3:PutObject")])
    error_message = "the only object the role may write is the state lock file"
  }
}
