output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "irsa_role_arns" {
  value = module.eks.irsa_role_arns
}

output "karpenter_role_arn" {
  value = module.eks.karpenter_role_arn
}

output "karpenter_queue_name" {
  value = module.eks.karpenter_queue_name
}
