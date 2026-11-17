# Chaos as code: an AWS FIS experiment template that sends a real Spot
# interruption notice to ONE running Spot node of pool "general", two minutes
# before EC2 reclaims it. Karpenter must receive it on its SQS queue, cordon
# and drain the node within the PodDisruptionBudgets and launch a replacement
# (live #3, docs/runbooks/live.md). The template costs nothing; each run is
# billed per action-minute, and it runs only when a person starts it in a
# live session: aws fis start-experiment --experiment-template-id <id>.
# No stop condition: one notice to one node cannot spread, and Grafana Cloud
# alerts are not CloudWatch alarms, which is all FIS can stop on.
# Gated by var.fis_enabled, off by default: an AWS Free Plan account (this
# one) gets SubscriptionRequiredException from FIS, and the apply would fail
# on the template. There, live #3 sends the same interruption warning as an
# EventBridge event to Karpenter's real queue instead (tests/live/).

resource "aws_iam_role" "fis" {
  count                = var.fis_enabled ? 1 : 0
  name                 = "${var.cluster_name}-fis"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.fis.account_id } }
    }]
  })
}

data "aws_caller_identity" "fis" {}

# Only Spot instances of this cluster's pool "general" can be interrupted.
resource "aws_iam_role_policy" "fis" {
  count = var.fis_enabled ? 1 : 0
  name  = "${var.cluster_name}-fis"
  role  = aws_iam_role.fis[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Describe", Effect = "Allow", Action = "ec2:DescribeInstances", Resource = "*" },
      {
        Sid      = "InterruptGeneralSpotOnly"
        Effect   = "Allow"
        Action   = "ec2:SendSpotInstanceInterruptions"
        Resource = "arn:${data.aws_partition.fis.partition}:ec2:*:${data.aws_caller_identity.fis.account_id}:instance/*"
        Condition = { StringEquals = {
          "aws:ResourceTag/karpenter.sh/nodepool" = "general"
          "aws:ResourceTag/eks:eks-cluster-name"  = var.cluster_name
        } }
      },
    ]
  })
}

data "aws_partition" "fis" {}

resource "aws_fis_experiment_template" "spot_interruption" {
  count       = var.fis_enabled ? 1 : 0
  description = "Spot interruption notice to one running Spot node of NodePool general (live #3)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-one-general-spot-node"
    action_id = "aws:ec2:send-spot-instance-interruptions"
    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }
    target {
      key   = "SpotInstances"
      value = "general-spot"
    }
  }

  target {
    name           = "general-spot"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"
    resource_tag {
      key   = "karpenter.sh/nodepool"
      value = "general"
    }
    resource_tag {
      key   = "eks:eks-cluster-name"
      value = var.cluster_name
    }
    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = { Name = "${var.cluster_name}-spot-interruption" }
}
