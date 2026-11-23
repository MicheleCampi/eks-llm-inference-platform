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
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:pull_request", "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:live-plan"]
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

run "apply_trust_is_live_environment_only" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:live" && !strcontains(aws_iam_role.apply.assume_role_policy, "*")
    error_message = "apply trust must be the live environment of this repo, immutable subject, no wildcard"
  }
}

run "apply_creates_roles_only_with_boundary" {
  command = plan
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.Condition.StringEquals["iam:PermissionsBoundary"] if s.Sid == "CreateStackRolesOnlyWithBoundary"]) == local.boundary_arn
    error_message = "CreateRole and PutRolePolicy must require the eks-llm-boundary"
  }
}

run "boundary_iam_is_karpenter_only" {
  command = plan
  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s.Action if s.Effect == "Allow" && can(s.Action)])) == toset(concat(local.karpenter_iam, ["iam:PassRole"]))
    error_message = "the boundary may grant in IAM only Karpenter's instance profile actions and PassRole"
  }
}

run "apply_cannot_touch_ci_identity" {
  command = plan
  assert {
    condition     = contains(one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.Resource if s.Sid == "DenyCiIdentityAndBoundary"]), local.boundary_arn)
    error_message = "apply role must be denied on the CI roles and on the boundary"
  }
}

run "apply_state_is_only_its_own_key" {
  command = plan
  assert {
    condition     = length(one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.NotResource if s.Sid == "DenyOtherStateObjects"])) == 2 && !strcontains(aws_iam_role_policy.apply_iam.policy, "s3:prefix")
    error_message = "apply role may read and write only this stack's state key and lock"
  }
}

run "grafana_roles_trust_one_environment_each" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role.grafana["plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:grafana-plan" && jsondecode(aws_iam_role.grafana["apply"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:grafana" && !strcontains(aws_iam_role.grafana["plan"].assume_role_policy, "*") && !strcontains(aws_iam_role.grafana["apply"].assume_role_policy, "*")
    error_message = "Each Grafana role must trust exactly its own environment."
  }
}

run "grafana_plan_writes_only_the_lock" {
  command = plan
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.grafana_state["plan"].policy).Statement : s.Resource if s.Sid == "WriteState"]) == ["${local.grafana_state_arn}.tflock"]
    error_message = "The Grafana plan role may write only the lock file."
  }
}

run "grafana_roles_reach_only_grafana_state" {
  command = plan
  assert {
    condition = alltrue(flatten([for k in ["plan", "apply"] : [for s in jsondecode(aws_iam_role_policy.grafana_state[k].policy).Statement : [
      alltrue([for a in flatten([s.Action]) : startswith(a, "s3:")]),
      alltrue([for r in flatten([s.Resource]) : contains(["arn:${local.partition}:s3:::${local.state_bucket}", local.grafana_state_arn, "${local.grafana_state_arn}.tflock"], r)]),
    ]]]))
    error_message = "Grafana roles may use only S3 on the bucket and the Grafana state and lock."
  }
}

run "grafana_roles_read_the_lock" {
  command = plan
  assert {
    condition     = alltrue([for k in ["plan", "apply"] : contains(flatten([for s in jsondecode(aws_iam_role_policy.grafana_state[k].policy).Statement : s.Resource if s.Sid == "ReadState"]), "${local.grafana_state_arn}.tflock")])
    error_message = "Each Grafana role must read its .tflock: the S3 lockfile reads it before releasing it."
  }
}

# service-linked-roles.tf imports the node group role; a mock provider cannot
# import, so the imported resource is overridden for every run.
override_resource {
  target = aws_iam_service_linked_role.eks_nodegroup
}

run "apply_reads_only_two_service_linked_roles" {
  command = plan
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.Action if s.Sid == "ReadServiceLinkedRoles"]) == "iam:GetRole" && length(one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.Resource if s.Sid == "ReadServiceLinkedRoles"])) == 2 && alltrue([for r in one([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : s.Resource if s.Sid == "ReadServiceLinkedRoles"]) : strcontains(r, ":role/aws-service-role/") && !strcontains(r, "*")])
    error_message = "The apply role may only read (iam:GetRole) the two service-linked roles, by exact ARN."
  }
}

run "cost_allocation_tags_active" {
  command = plan
  assert {
    condition     = toset([for t in aws_ce_cost_allocation_tag.this : t.tag_key if t.status == "Active"]) == toset(["Project", "Session"])
    error_message = "Project and Session must be active cost allocation tags, kept outside the cluster stack"
  }
}
