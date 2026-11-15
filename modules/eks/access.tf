# Human cluster administrators, as code. bootstrap_cluster_creator_admin_permissions
# makes only the pipeline role an admin; live attempt 2 found no human could reach
# the API. Each principal gets an access entry and AmazonEKSClusterAdminPolicy.
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.key].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

output "cluster_admins" {
  description = "Human cluster admins: principal ARN to access policy and scope."
  value = { for k, v in aws_eks_access_policy_association.admin : k => {
    policy_arn = v.policy_arn
    scope      = v.access_scope[0].type
  } }
}
