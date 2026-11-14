# eks-llm-inference-platform

[![ci](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/workflows/ci.yml)

An AWS EKS cluster provisioned with Terraform, where ArgoCD deploys a
Kubernetes operator from Git and the only manual `kubectl apply`s are the
AppProjects and the root Application, from a release tag.

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
      ├── modules/vpc   VPC across 2 AZs: public subnets (IGW, NAT, load balancers),
      │                 private subnets (nodes), S3 gateway endpoint
      └── modules/eks   EKS 1.36 (API auth mode), managed node group
    ArgoCD (app-of-apps)
      ├── gitops/root-app.yaml            -> watches gitops/apps/
      ├── gitops/apps/…operator.yaml      -> Helm chart from operator repo
      ├── gitops/apps/external-secrets.yaml -> ESO; gitops/monitoring/ syncs the
      │                                       Grafana Cloud Secret from AWS Secrets Manager
      ├── gitops/apps/alloy.yaml            -> Karpenter metrics to Grafana Cloud
      └── gitops/apps/kyverno.yaml, policies.yaml -> admission policies (gitops/policies/)

Manual applies: the AppProjects, then the root Application, from a release
tag; everything else reconciles from Git.

## Design decisions

- **Nodes in private subnets, egress through NAT.** Managed nodes and
  Karpenter nodes get no public IP; the API endpoint has private access on
  and public access restricted to `public_access_cidrs`. `nat_mode` is
  `single` (one NAT, $0.048/h in eu-west-1 from the AWS Pricing API, plus
  data): a lab trade-off, since losing that AZ cuts egress for both.
  Production sets `per_az`. VPC endpoints alone are not enough: the Karpenter
  chart comes from public.ecr.aws. The S3 gateway endpoint (free) keeps ECR
  layer pulls off the NAT. Tested in `modules/vpc/tests/nat.tftest.hcl`;
  not yet applied live.
- **CPU-only nodes; example VLLMService disabled.** This capstone proves the
  IaC->GitOps->operator chain. GPU serving behavior of the same operator is
  measured elsewhere (3x A10 fleet: replacement Ready in 57s, make-before-break,
  max gap 2.3s) - see the operator repo. The per-node reporter is off (the
  chart default), so nothing writes NodeState on this cluster.
- **Observability as on GKE, keyless.** Alloy scrapes the Karpenter controller
  (`http-metrics`) and keeps only `up` and the node, scheduling, NodePool,
  disruption and interruption series, then remote-writes to Grafana Cloud.
  Its credentials live in AWS Secrets Manager, created empty by Terraform so
  the value never enters state; External Secrets Operator reads them through
  EKS Pod Identity with a role allowed only that secret. `ci/validate-gitops.sh`
  checks chart pins and SHA-256, manifests against the deployed CRDs, the
  service account, secret name and metrics port wiring, and the Alloy config
  with Alloy itself, with negative cases. Three alerts (NodePool CPU limit
  reached, controller down, Spot interruption) live in
  `observability/karpenter-rules.yaml`, Prometheus format for promtool and
  Grafana-managed rules alike, with promtool tests, a runbook
  (`docs/runbooks/karpenter.md`) and a dashboard
  (`observability/karpenter-dashboard.json`); metric and label names are read
  from the Karpenter v1.15.1 code, and `ci/metrics-shipped.py` fails if Alloy
  drops a metric they use. Not yet applied live.
- **Admission policies with Kyverno, enforced.** Four `ValidatingPolicy`
  (`policies.kyverno.io/v1`, CEL; the classic `ClusterPolicy` API is deprecated
  in chart 3.10.0) deny images without a version tag or digest, containers
  without CPU and memory requests, and privileged containers, for Pods and
  their controllers; and `team-*` namespaces without the team and cost-centre
  labels, or whose team label differs from the namespace name. Exempt, with
  the reason in the policy: `kube-system`,
  `kyverno`, and `argocd` (installed from the upstream manifest). The platform
  obeys the same rules: ESO and Alloy get starting requests, to be checked
  against usage measured live. `ci/validate-gitops.sh` runs the Kyverno CLI
  (v1.20.0, SHA-256 pinned) on ESO, Alloy and the operator rendered with the
  values ArgoCD deploys, and on fixtures that must be rejected. Not yet
  applied live.
- **Right-sizing as a continuous FinOps loop.** metrics-server runs as an EKS
  managed add-on, pinned (v0.9.1-eksbuild.1), with 2 replicas across zones and
  a PodDisruptionBudget declared, so `kubectl top` and the HPA survive a node
  removed by Karpenter consolidation. kube-state-metrics (chart 9.0.1) exports
  only pod requests and namespace and node labels; Alloy scrapes cAdvisor on the
  kubelet with TLS verified against the cluster CA and `nodes/metrics` only,
  and keeps six series families, a deliberate bound for the Grafana Cloud free
  plan. `observability/rightsizing-dashboard.json` shows requests against usage
  and idle CPU per namespace, CPU requests per team taken from the namespace
  label `platform.michelecampi.dev/team` (showback) and
  nodes by capacity type and zone. The node group image, the Pod Identity
  agent and metrics-server are pinned and asserted by `terraform test`, so a
  change of AWS default cannot alter the cluster silently. Starting requests,
  label names and kubelet TLS are checked live; not yet applied live.
- **Multi-tenancy with a spending cap per team.** Each team gets a namespace
  labelled with its team and cost centre, a ResourceQuota (the team's cap),
  a LimitRange, a default-deny ingress NetworkPolicy (egress open) and RBAC
  that cannot change its
  own quota or limits (`gitops/tenants/demo/`). The platform owns these through
  the AppProject `tenancy`; the team deploys only its own namespace through
  the AppProject `team-demo`. `ci/check-tenancy.py` fails if a team Role can
  edit quotas or limits. NetworkPolicy is enforced by the vpc-cni managed
  add-on (v1.22.4-eksbuild.14, network policy enabled); every add-on's
  configuration lives in `modules/eks/addons/*.json` and `ci/addon-config.py`
  validates it against the AWS schema of the pinned version. Not yet applied
  live.
- **AWS Budget as code, at no charge.** `modules/budget` declares a monthly
  cost budget (5 USD by default) that counts only spend tagged `Project`, with
  alerts on actual spend past 80% and forecast spend past 100% when
  `budget_alert_emails` is set (in `terraform.tfvars`, not committed). It has
  no actions and no reports, which AWS Budgets does not charge for; `Project`
  is activated as a cost allocation tag. The tags come from one map
  (`local.tags` in `providers.tf`) and reach the Karpenter nodes (EC2NodeClass
  `spec.tags`, compared by `ci/check-cost-tags.py`) and the node group's
  instances, volumes and ENIs (launch template `tag_specifications`).
  `terraform test` asserts the filter, the alerts and the node tags. Not yet
  applied live.
- **Misconfiguration scan with trivy, blocking.** `ci/validate-gitops.sh` runs
  `trivy config` (v0.76.2 from inference-platform-ci v0.3.0: release binary,
  Sigstore signature verified before pinning, not `trivy-action`) on Terraform
  and manifests with the checks built into that binary (`--skip-check-update`);
  any HIGH or CRITICAL finding fails CI, and `neg-trivy-public-ip` proves it
  does. Fixed: no automatic public IPs in the public subnets (AWS-0164).
  Accepted in `.trivyignore`, each with its reason and an expiry: AWS-0039
  (EKS 1.28+ already encrypts all API data with an AWS owned key) and AWS-0040
  (public endpoint limited to `public_access_cidrs`, private access on).
  Skipped: `ci/fixtures` (deliberately bad) and the upstream Karpenter
  CloudFormation copy. Not yet scanned: Helm charts rendered with our values.
- **terraform plan on pull requests, via OIDC, no stored keys.** The `plan` job
  gets a GitHub OIDC token with `curl` and lets Terraform assume
  `eks-llm-ci-plan` through `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`
  (no third-party action). The role (`bootstrap/ci-identity`, outside the
  cluster stack) trusts only this repo's pull requests by immutable subject
  (`repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:pull_request`),
  has `ReadOnlyAccess`, reads this stack's state and writes only its lock file.
  Explicit Deny on every other S3 object and on secret values, because
  `ReadOnlyAccess` alone reads every bucket, other projects' state included.
  The GitHub OIDC provider is shared with aws-ecs-delivery-platform and only
  read here. `terraform test` asserts trust and state access.
- **Argo CD governance: least-privilege projects, release tags.** The add-ons
  and the root app are in AppProject `platform`: 7 source repos, 6
  destination namespaces and 8 cluster-scoped kinds, the ones the charts and
  manifests create, nothing else; `default` is closed. Teams stay in `tenancy`
  and `team-*`. `ci/check-project-kinds.py` renders every app (CRDs included)
  and fails on a cluster-scoped kind the project does not allow; two negative
  cases cover a built-in kind and a CRD kind (scope read from the CRD). Built-in
  kinds come from a list in the script: a rare one missing there would not be
  caught. Every Application from this repo deploys the same release tag,
  checked by `ci/check-release-pin.py` (negative case: an app on `main`).
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

The CI identity for `terraform plan` is applied once, by hand (CI cannot
create the role it assumes), then its ARN is set as a repo variable:

    terraform -chdir=bootstrap/ci-identity init && terraform -chdir=bootstrap/ci-identity apply
    gh variable set AWS_PLAN_ROLE_ARN --body "$(terraform -chdir=bootstrap/ci-identity output -raw plan_role_arn)"

## Run it

    terraform init && terraform apply        # 2 Ready nodes
    aws eks update-kubeconfig --region eu-west-1 --name llm-inference
    kubectl create ns argocd
    kubectl apply -n argocd --server-side -f \
      https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml
    git checkout v2.0.0                      # the release the cluster runs
    kubectl apply -f gitops/apps/projects.yaml  # first: the root app belongs to project platform
    kubectl apply -f gitops/root-app.yaml    # deploys the tag in targetRevision
    terraform destroy                        # stop the meter

## Release and rollback

The cluster runs a release tag, never `main`. To promote:

1. A PR sets the new tag (`vX.Y.Z`) in every Application sourced from this
   repo; `ci/check-release-pin.py` rejects a branch or mixed tags.
2. Merge, then tag the merge commit: `git tag -a vX.Y.Z -m ... && git push origin vX.Y.Z`.
3. `git checkout vX.Y.Z && kubectl apply -f gitops/root-app.yaml`.

Rollback is the same with the previous tag.

## Verify

Every check runs offline of AWS, with no credentials, the same way in CI (`.github/workflows/ci.yml`) and locally:

    bash ci/install-tools.sh   # from inference-platform-ci v0.2.0: terraform 1.15.8, gitleaks, actionlint, helm, kubeconform, yq, openapi2jsonschema, each SHA-256 verified; PyYAML and jsonschema, every hash checked
    bash ci/validate.sh        # fmt, init -backend=false, validate, terraform test (mock aws provider), gitleaks on full history, actionlint

Not checked: no misconfiguration scan (trivy) yet, and no plan or apply against a real AWS account.
