# eks-llm-inference-platform

[![ci](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/workflows/ci.yml)

An AWS EKS cluster provisioned with Terraform, where ArgoCD deploys a
Kubernetes operator from Git and the only manual `kubectl apply` is the root
Application.

**What it shows**

- **Terraform**: VPC and EKS 1.36 modules, EKS access entries instead of the
  aws-auth ConfigMap, S3 state with native locking; `terraform test` runs in
  CI against a mocked AWS provider ([`tests/`](tests/)).
- **GitOps**: an ArgoCD app-of-apps reconciles the operator's Helm chart from
  Git ([`gitops/`](gitops/)).
- **Guardrails**: the public API endpoint is reachable only from declared
  CIDRs; an empty list or `0.0.0.0/0` fails at plan time, and both cases are
  tested ([`variables.tf`](variables.tf),
  [`tests/public_access_cidrs.tftest.hcl`](tests/public_access_cidrs.tftest.hcl)).
- **Evidence**: one end-to-end run on a real account, recorded below.

IaC-to-GitOps LLM inference platform on AWS EKS, the AWS counterpart of
[gke-llm-inference-platform](https://github.com/MicheleCampi/gke-llm-inference-platform):
the same operator project, deployed through an ArgoCD app-of-apps, on a
different cloud. This platform pins the operator at release `v0.4.0`; the GKE
platform pins `v0.9.0`
([`argocd/apps/operator.yaml`](https://github.com/MicheleCampi/gke-llm-inference-platform/blob/main/argocd/apps/operator.yaml)).

**E2E validated 2026-07-13** ([evidence](docs/evidence/e2e-2026-07-13.md)):
Terraform-managed EKS 1.36 (2 nodes Ready), ArgoCD app-of-apps Synced/Healthy,
[vllm-coldstart-operator](https://github.com/MicheleCampi/vllm-coldstart-operator)
(Rust, kube-rs) deployed via GitOps, 3 CRDs served.

That run predates the pin: the app tracked the operator's `main` (`e93e7c1`),
whose chart installed image `0.2.1`. The three CRDs were served, but that
binary reconciles only VllmService. The cycle has not been repeated at
`v0.4.0`.

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
  max gap 2.3s) - see the operator repo. The per-node reporter is off (the
  chart default), so nothing writes NodeState on this cluster.
- **EKS access entries (API mode)**, not the legacy aws-auth ConfigMap.
- **Public API endpoint restricted** with `public_access_cidrs`, set at apply
  time and never committed. EKS treats an empty list as open to the internet,
  so a validation rule rejects it, and `0.0.0.0/0` too.
- **S3 native state locking** (`use_lockfile`, Terraform >= 1.10), no DynamoDB.
- **Ephemeral by design**: the cluster exists as a reproducible artifact
  (recreated with the steps in "Run it"), not as an idle bill.

## Findings

1. **Free Plan accounts restrict EC2 to free-tier-eligible instance types.**
   t3.medium failed at ASG launch (`InvalidParameterCombination`);
   `m7i-flex.large` (2 vCPU / 8 GiB) is eligible and larger. Documented in
   `main.tf`.
2. **ArgoCD install manifest needs `--server-side`** on current Kubernetes:
   the applicationsets CRD exceeds the 256 KiB annotation limit of
   client-side apply.
3. **CRD `ignoreDifferences` generalized** after fleet CRDs (ADR-0003)
   were added post-GKE: fixed in Git, reconciled by ArgoCD - no kubectl.

## Bootstrap (one-time, out-of-band)

The S3 state bucket is the only resource created outside Terraform:

    aws s3api create-bucket --bucket michele-tfstate-eks-llm \
      --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1
    aws s3api put-bucket-versioning --bucket michele-tfstate-eks-llm \
      --versioning-configuration Status=Enabled

## Run it

    terraform init && terraform apply        # 2 Ready nodes
    aws eks update-kubeconfig --region eu-west-1 --name llm-inference
    kubectl create ns argocd
    kubectl apply -n argocd --server-side -f \
      https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml
    kubectl apply -f gitops/root-app.yaml    # the only manual apply
    terraform destroy                        # stop the meter

## Verify

Every check runs offline of AWS, with no credentials, the same way in CI (`.github/workflows/ci.yml`) and locally:

    bash ci/install-tools.sh   # terraform 1.15.8, gitleaks, actionlint from inference-platform-ci v0.1.0, each SHA-256 verified
    bash ci/validate.sh        # fmt, init -backend=false, validate, terraform test (mock aws provider), gitleaks on full history, actionlint

Not checked: no misconfiguration scan (trivy) yet, and no plan or apply against a real AWS account.
