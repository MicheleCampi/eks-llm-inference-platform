# eks-llm-inference-platform

IaC-to-GitOps LLM inference platform on AWS EKS. AWS twin of
[gke-llm-inference-platform](https://github.com/MicheleCampi/gke-llm-inference-platform):
same GitOps contract, same operator, different cloud.

**E2E validated 2026-07-13** ([evidence](docs/evidence/e2e-2026-07-13.md)):
Terraform-managed EKS 1.36 (2 nodes Ready), ArgoCD app-of-apps Synced/Healthy,
[vllm-coldstart-operator](https://github.com/MicheleCampi/vllm-coldstart-operator)
(Rust, kube-rs) deployed via GitOps, 3 CRDs served. Full build-validate-destroy
cycle in a single session, ~$1 total cost.

## Architecture

    Terraform (S3 backend, native lockfile)
      ├── modules/vpc   VPC, 2 public subnets across 2 AZs, IGW
      └── modules/eks   EKS 1.36 (API auth mode), managed node group
    ArgoCD (app-of-apps)
      ├── gitops/root-app.yaml            -> watches gitops/apps/
      └── gitops/apps/…operator.yaml      -> Helm chart from operator repo

The only manual `kubectl apply` is the root Application; everything else
reconciles from Git.

## Design decisions

- **No NAT Gateway.** Public subnets only; nodes get public IPs with
  ingress-closed security groups. Lab cost profile, stated trade-off.
- **CPU-only nodes; example VLLMService disabled.** This capstone proves the
  IaC->GitOps->operator chain. GPU serving behavior of the same operator is
  measured elsewhere (3x A10 fleet: replacement Ready in 57s, make-before-break,
  max gap 2.3s) - see the operator repo.
- **EKS access entries (API mode)**, not the legacy aws-auth ConfigMap.
- **S3 native state locking** (`use_lockfile`, Terraform >= 1.10), no DynamoDB.
- **Ephemeral by design**: cluster exists as a reproducible artifact
  (~20 min to recreate), not as an idle bill.

## Findings

1. **Free Plan accounts restrict EC2 to free-tier-eligible instance types.**
   t3.medium failed at ASG launch (`InvalidParameterCombination`);
   `m7i-flex.large` (2 vCPU / 8 GiB) is eligible and larger. Documented in
   `main.tf`.
2. **ArgoCD install manifest needs `--server-side`** on current Kubernetes:
   the applicationsets CRD exceeds the 256 KiB annotation limit of
   client-side apply.
3. **CRD `ignoreDifferences` generalized** after fleet CRDs (ADR-0005/0006)
   were added post-GKE: fixed in Git, reconciled by ArgoCD - no kubectl.

## Bootstrap (one-time, out-of-band)

The S3 state bucket is the only resource created outside Terraform:

    aws s3api create-bucket --bucket michele-tfstate-eks-llm \
      --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1
    aws s3api put-bucket-versioning --bucket michele-tfstate-eks-llm \
      --versioning-configuration Status=Enabled

## Run it

    terraform init && terraform apply        # ~15 min to 2 Ready nodes
    aws eks update-kubeconfig --region eu-west-1 --name llm-inference
    kubectl create ns argocd
    kubectl apply -n argocd --server-side -f \
      https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl apply -f gitops/root-app.yaml    # the only manual apply
    terraform destroy                        # stop the meter
