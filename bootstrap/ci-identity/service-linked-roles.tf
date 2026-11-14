# Account-wide service-linked roles the cluster stack needs. They are account
# baseline, applied once with administrator credentials: a stack destroy must
# not delete them, and the CI apply role may only read them (apply.tf,
# ReadServiceLinkedRoles). Live attempt 1 (2026-11-14) failed on both.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}

# Created by AWS on 2026-07-13 with the first managed node group: imported, not
# recreated.
import {
  to = aws_iam_service_linked_role.eks_nodegroup
  id = "arn:${local.partition}:iam::${local.account}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"
}

resource "aws_iam_service_linked_role" "eks_nodegroup" {
  aws_service_name = "eks-nodegroup.amazonaws.com"
}
