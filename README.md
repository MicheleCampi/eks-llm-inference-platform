# eks-llm-inference-platform

IaC-to-GitOps LLM inference platform on AWS EKS. AWS twin of
[gke-llm-inference-platform](https://github.com/MicheleCampi/gke-llm-inference-platform):
Terraform-managed EKS cluster, ArgoCD app-of-apps, vllm-coldstart-operator
deployed via GitOps.

## State backend bootstrap (one-time, out-of-band)

The S3 state bucket is the only resource created outside Terraform:

    aws s3api create-bucket --bucket michele-tfstate-eks-llm \
      --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1
    aws s3api put-bucket-versioning --bucket michele-tfstate-eks-llm \
      --versioning-configuration Status=Enabled

State locking uses S3 native lockfile (`use_lockfile = true`, Terraform >= 1.10).

## Layout

- `modules/vpc` — lab VPC: public subnets only (no NAT Gateway by design; lab cost profile)
- `modules/eks` — EKS cluster + managed node group

## Status

Skeleton. Cluster build in progress.
