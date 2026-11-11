# Karpenter v1.15.1. Controller policies come verbatim from the official
# CloudFormation (ci/karpenter/cloudformation-v1.15.1.yaml, ci/karpenter/extract.py).
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  karpenter_policies = toset(["EKSIntegrationPolicy", "IAMIntegrationPolicy", "InterruptionPolicy", "NodeLifecyclePolicy", "ResourceDiscoveryPolicy", "ZonalShiftPolicy"])
  karpenter_vars = {
    partition     = data.aws_partition.current.partition
    region        = data.aws_region.current.region
    account_id    = data.aws_caller_identity.current.account_id
    cluster_name  = var.cluster_name
    queue_arn     = aws_sqs_queue.karpenter.arn
    node_role_arn = aws_iam_role.node.arn
  }
}

resource "aws_iam_policy" "karpenter" {
  for_each = local.karpenter_policies
  name     = "${var.cluster_name}-karpenter-${each.key}"
  policy   = templatefile("${path.module}/karpenter-policies/${each.key}.json.tpl", local.karpenter_vars)
}

# The controller's role is assumed through EKS Pod Identity, bound below to
# exactly one service account: kube-system/karpenter. No role ARN in git.
resource "aws_iam_role" "karpenter" {
  name = "${var.cluster_name}-karpenter"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  for_each   = local.karpenter_policies
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter[each.key].arn
}

resource "aws_sqs_queue" "karpenter" {
  name                      = var.cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy = jsonencode({
    Id = "EC2InterruptionPolicy"
    Statement = [
      { Effect = "Allow", Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }, Action = "sqs:SendMessage", Resource = aws_sqs_queue.karpenter.arn },
      { Sid = "DenyHTTP", Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.karpenter.arn, Condition = { Bool = { "aws:SecureTransport" = false } } },
    ]
  })
}

locals {
  karpenter_events = {
    scheduled-change     = { source = "aws.health", detail = "AWS Health Event" }
    spot-interruption    = { source = "aws.ec2", detail = "EC2 Spot Instance Interruption Warning" }
    rebalance            = { source = "aws.ec2", detail = "EC2 Instance Rebalance Recommendation" }
    instance-state       = { source = "aws.ec2", detail = "EC2 Instance State-change Notification" }
    capacity-reservation = { source = "aws.ec2", detail = "EC2 Capacity Reservation Instance Interruption Warning" }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.karpenter_events
  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({ source = [each.value.source], "detail-type" = [each.value.detail] })
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = local.karpenter_events
  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter.arn
}

# EC2NodeClass finds subnets and the cluster security group by this tag.
resource "aws_ec2_tag" "karpenter_subnet" {
  count       = length(var.subnet_ids)
  resource_id = var.subnet_ids[count.index]
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "karpenter_sg" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter.arn
}

# Spot launches need this account-wide role; absent in this account (checked 2026-11-11).
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}
