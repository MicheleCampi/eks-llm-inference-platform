# Grafana as code (observability/terraform, workflow observability.yml): plan
# from environment grafana-plan, apply from the protected environment grafana.
# No managed policy: the Grafana provider calls no AWS API, so the only AWS
# access is the Grafana state object. Everything else is implicitly denied.
locals {
  grafana_state_key     = "eks-llm-inference-platform/grafana.tfstate"
  grafana_state_arn     = "arn:${local.partition}:s3:::${local.state_bucket}/${local.grafana_state_key}"
  grafana_plan_subject  = "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:grafana-plan"
  grafana_apply_subject = "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:grafana"
}

resource "aws_iam_role" "grafana" {
  for_each             = { plan = local.grafana_plan_subject, apply = local.grafana_apply_subject }
  name                 = "eks-llm-ci-grafana-${each.key}"
  description          = "GitHub Actions Grafana ${each.key}, one environment only"
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
          "token.actions.githubusercontent.com:sub" = each.value
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "grafana_state" {
  for_each = aws_iam_role.grafana
  name     = "grafana-state-${each.key}"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ListStateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:${local.partition}:s3:::${local.state_bucket}" },
      { Sid = "ReadState", Effect = "Allow", Action = "s3:GetObject", Resource = local.grafana_state_arn },
      # plan writes only the lock file; apply also writes the state.
      { Sid = "WriteState", Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject"], Resource = each.key == "apply" ? [local.grafana_state_arn, "${local.grafana_state_arn}.tflock"] : ["${local.grafana_state_arn}.tflock"] },
    ]
  })
}

output "grafana_role_arns" {
  value = { for k, r in aws_iam_role.grafana : k => r.arn }
}
