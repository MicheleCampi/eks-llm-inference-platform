output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "irsa_role_arns" {
  value = { for k, r in aws_iam_role.irsa : k => r.arn }
}

output "karpenter_role_arn" {
  value = aws_iam_role.karpenter.arn
}

output "karpenter_queue_name" {
  value = aws_sqs_queue.karpenter.name
}

output "control_plane_log_types" {
  value = aws_eks_cluster.this.enabled_cluster_log_types
}

output "control_plane_log_group" {
  value = one(aws_cloudwatch_log_group.control_plane[*].name)
}

output "control_plane_log_retention_days" {
  value = one(aws_cloudwatch_log_group.control_plane[*].retention_in_days)
}
