module "vpc" {
  source = "./modules/vpc"

  name     = var.cluster_name
  vpc_cidr = var.vpc_cidr
}

module "eks" {
  source = "./modules/eks"

  cluster_name             = var.cluster_name
  kubernetes_version       = "1.36"
  subnet_ids               = module.vpc.private_subnet_ids
  public_access_cidrs      = var.public_access_cidrs
  irsa_roles               = var.irsa_roles
  permissions_boundary_arn = local.permissions_boundary_arn

  # Free Plan accounts restrict EC2 to free-tier-eligible types only
  # (t3.medium rejected with InvalidParameterCombination at ASG launch).
  node_instance_types = ["m7i-flex.large"]
}

# Every IAM role of the stack carries this boundary. It is created in
# bootstrap/ci-identity (eks-llm-boundary); the apply role may create roles
# only with it. Built from the account, so no input can point it elsewhere.
data "aws_caller_identity" "boundary" {}
data "aws_partition" "boundary" {}

locals {
  permissions_boundary_arn = "arn:${data.aws_partition.boundary.partition}:iam::${data.aws_caller_identity.boundary.account_id}:policy/eks-llm-boundary"
}
