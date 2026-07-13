module "vpc" {
  source = "./modules/vpc"

  name     = var.cluster_name
  vpc_cidr = var.vpc_cidr
}

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = "1.36"
  subnet_ids         = module.vpc.public_subnet_ids

  # Free Plan accounts restrict EC2 to free-tier-eligible types only
  # (t3.medium rejected with InvalidParameterCombination at ASG launch).
  node_instance_types = ["m7i-flex.large"]
}
