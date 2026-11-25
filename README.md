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
different cloud. EKS pins the operator at release `v0.13.0`
([`gitops/apps/vllm-coldstart-operator.yaml`](gitops/apps/vllm-coldstart-operator.yaml)),
which serves a model on CPU (`gpu: 0` with `cpu` and `memory` set, since
`v0.12.0`) and passes engine settings without a CLI flag through `spec.env`;
GKE pins its own release in
[`argocd/apps/operator.yaml`](https://github.com/MicheleCampi/gke-llm-inference-platform/blob/main/argocd/apps/operator.yaml).

**What ran live on EKS, and what did not.**

- 2026-07-13 ([evidence](docs/evidence/e2e-2026-07-13.md)): Terraform-managed
  EKS 1.36 (2 nodes Ready), ArgoCD app-of-apps Synced/Healthy, the operator
  deployed via GitOps, 3 CRDs served. That run tracked the operator's `main`
  (`e93e7c1`), whose chart installed image `0.2.1`, a binary that reconciles
  only VllmService. It served no model.
- 2026-11-15 ([evidence](docs/evidence/live-2026-11-15.md)): the platform
  layer (Karpenter, ESO, Alloy, Kyverno, alerts, teardown), with a `pause`
  pod as load. The operator Application (then `v0.4.0`) was in the
  app-of-apps, but the evidence records nothing about it, so nothing about
  the operator is claimed from that run. Real cost, read from AWS Cost
  Explorer on 2026-11-17 (usage, before credits): 0.149 USD for the failed
  first attempt on 2026-11-14 and 1.195 USD for this run, against estimates
  of 0.10-0.15 and ~1.3 USD; both fully covered by account credits.
- 2026-11-17, live #3 ([evidence](docs/evidence/live-2026-11-17.md)):
  Karpenter under real disruption. A Spot interruption warning on its real
  SQS queue gave a replacement node Ready in 53 s with the PDB never below 0;
  drift replaced 3 nodes one at a time within the 20% budget; IMDS was
  blocked from a pod; the NodePool CPU limit and the gated `gpu` pool both
  refused a node. The operator `v0.12.0`, deployed by Argo CD, created the
  CPU model pod on a Karpenter `m7i-flex.large` Spot node, but the pod was
  OOMKilled: vLLM CPU reserves a fixed 4 GiB KV cache (Findings #5).
- 2026-11-18, live #4 ([evidence](docs/evidence/live-2026-11-18.md)): a
  model served on EKS. The operator `v0.13.0`, deployed by Argo CD, set
  `VLLM_CPU_KVCACHE_SPACE=1` through `spec.env`; Karpenter launched a Spot
  `m7i-flex.large` and the VllmService was Ready 118 s after the apply.
  Qwen2.5-0.5B on vLLM CPU v0.11.2 answered 20 requests out of 20 with HTTP
  200 (p50 3.83 s, max 19.17 s on the first, cold request), 0 restarts,
  4130Mi used of the 6Gi limit. The same settings had been run free in Docker
  first (peak 5.0 GiB, 20 out of 20). CPU latency, not a GPU benchmark: GPU
  serving by the same operator was measured on GKE and on a 3x A10 fleet,
  see the operator repo.
- 2026-11-22, live #7 ([evidence](docs/evidence/live-a021-2026-11-22.md)):
  release v2.4.0 on current versions (Argo CD 3.6.2, ESO 2.15, Karpenter
  1.15.3, operator v0.17.0, vLLM CPU v0.34.0) came up from Git, 11 of 12
  Applications Healthy (Kyverno reports RBAC, fixed in #81). On vLLM v0.34.0
  in eager mode, same nodes and probe as v0.11.2: Ready 3 min 23 s after the
  apply, first request after Ready 8.35 s, steady p50 5.86 s against 3.81 s
  on v0.11.2; 169 requests, 0 failed, including a rolling update of both
  replicas. The steady-state gap is open (finding 3).
- 2026-11-22, live #8 ([evidence](docs/evidence/live-a022-2026-11-22.md)):
  release v2.4.1 came up from Git with all 12 Applications Synced and
  Healthy (the Kyverno fix works live), every node on AMI 1.36.5-20261119.
  A/B on one m7i-flex.large Spot node (Intel Xeon Platinum 8488C, Sapphire
  Rapids), same pod and probe: vLLM CPU v0.11.2 p50 3.69 s, v0.34.0 5.37 s,
  v0.11.2 again 3.71 s, 293 requests, 0 failed. v0.34.0 is 1.45 x slower at
  steady state on this CPU; in CI on Granite Rapids (Xeon 6975P) the gap is
  at most ~10 %. First request after Ready on v0.34.0: 5.34 s, already warm.
  Bisected the next day on the same CPU in plain Docker
  ([A-023](docs/evidence/bisect-a023-2026-11-22.md)): the step is between
  v0.19.1 (p50 3.79 s) and v0.20.2 (5.73 s), +51 %, with time to Ready from
  30 s to 70 s at the same release.
  Then [A-024](docs/evidence/a024-torch-vs-vllm-2026-11-22.md) ruled
  torch out: v0.20.0 is already slow (p50 6.07 s against 3.85 s), while a
  torch-only bf16 linear at decode shapes costs the same with the torch of
  v0.19.1 (2.10) and of v0.20.0 (2.11), on the same AMX kernel. The step is in
  vLLM's own v0.20.0 code.
  Cause, measured on 2-core runners: since v0.20.0 (vLLM #36487) the CPU
  backend reserves a core for the scheduler process, so on small machines
  decode runs on half the cores; `VLLM_CPU_NUM_OF_RESERVED_CPU=0` takes back
  most of it (+61 % to +7 %).
- 2026-11-25, live #9 ([evidence](docs/evidence/live-a025-2026-11-25.md)):
  release v2.4.3 (operator v0.18.0) came up from Git with the Session cost
  tag, 12 of 12 Applications Healthy. Prefix-aware routing on EKS across two
  zones: llm-d-router v1.0.0 with its default configuration in front of 2
  vLLM CPU v0.34.0 replicas on m7i-flex.large (Xeon 8488C), against the
  operator's Service, 3 repetitions: prefix-cache hit 0.84 against 0.52,
  TTFT p50 0.43 s against 1.43 s; the llm-d-router #2059 scorers matched the
  legacy ones (hit 0.762 against 0.747, TTFT p50 -7 %); 1919 of 1920
  requests ok, one Envoy 503 "connection termination". S3'' deferred; the
  session ran about 1 hour over its time limit (finding 1).

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

- **Three node pools, each with one job.** `system` is the managed node
  group (On-Demand, not managed by Karpenter, so Karpenter never drains the
  node it runs on) for the platform controllers. `general`
  (`gitops/karpenter/nodepool-general.yaml`) is Spot-first with On-Demand
  fallback; on this Free Plan account it can use only 3 instance types
  (Findings #1), and the file carries the attribute selectors that replace
  that list on a paid account. `gpu` (`nodepool-gpu.yaml`) is tainted
  `nvidia.com/gpu:NoSchedule`, On-Demand only, consolidated only when empty,
  and **gated**: its limits are 0, so it launches nothing until a reviewed PR
  raises them, adds the NVIDIA device plugin and a quota increase. The file
  lists those steps. Every node carries `platform.michelecampi.dev/pool`.
- **Node disruption is bounded.** The `general` pool replaces nodes after
  24h (`expireAfter`), so a pinned-AMI bump reaches every node within a day;
  caps any drain at 1h (`terminationGracePeriod`), so a blocking
  PodDisruptionBudget cannot stall expiry or drift; and declares disruption
  budgets: at most 20% of nodes at once, and no drift replacement
  08:00-18:00 UTC on weekdays. Spot interruptions are not voluntary and
  ignore budgets.
- **Pools checked in CI.** kubeconform validates every NodePool and
  EC2NodeClass against the CRDs of the Karpenter chart Argo CD deploys
  (v1.15.3); `ci/check-nodepools.py` enforces what a schema cannot: a cost
  cap, bounded node life and drain, budgets, IMDSv2 with hop limit 1, a pinned
  AMI, the cost tag, and that only a tainted pool can launch GPU instances.
  Six negative cases prove each rule rejects. CEL rules of the CRDs run only
  at the API server. Not yet exercised live.
- **Nodes in private subnets, egress through NAT.** Managed nodes and
  Karpenter nodes get no public IP; the API endpoint has private access on
  and public access restricted to `public_access_cidrs`. `nat_mode` is
  `single` (one NAT, $0.048/h in eu-west-1 from the AWS Pricing API, plus
  data): a lab trade-off, since losing that AZ cuts egress for both.
  Production sets `per_az`. VPC endpoints alone are not enough: the Karpenter
  chart comes from public.ecr.aws. The S3 gateway endpoint (free) keeps ECR
  layer pulls off the NAT. Tested in `modules/vpc/tests/nat.tftest.hcl`;
  applied live on 2026-11-15 (one NAT, removed at teardown).
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
  with Alloy itself, with negative cases. Ten alerts (seven on Karpenter and nodes, three on workloads since v2.3.6) live in
  `observability/karpenter-rules.yaml`, Prometheus format for promtool and
  Grafana-managed rules alike, with promtool tests, a runbook
  per group (`docs/runbooks/karpenter.md`, `docs/runbooks/workloads.md`) and a dashboard
  (`observability/karpenter-dashboard.json`); metric and label names are read
  from the Karpenter v1.15.1 code, and `ci/metrics-shipped.py` fails if Alloy
  drops a metric they use. Pages: NodePool CPU limit reached, controller
  down, pods unschedulable for 15 min, node NotReady for 10 min. Tickets:
  Spot interruption, NodeClaim launch or registration failed, insufficient
  capacity 3 times in 30 min. NodeClaim failures come from
  `karpenter_nodeclaims_disrupted_total` by reason, as Karpenter v1.15.1
  records them (core `nodeclaim/lifecycle`); NotReady from
  kube-state-metrics, with only the Ready condition shipped. Not yet applied
  live.
- **Admission policies with Kyverno, enforced.** Seven `ValidatingPolicy`
  (`policies.kyverno.io/v1`, CEL; the classic `ClusterPolicy` API is deprecated
  in chart 3.10.0) deny images without a version tag or digest, containers
  without CPU and memory requests, and privileged containers, for Pods and
  their controllers; and `team-*` namespaces without the team and cost-centre
  labels, or whose team label differs from the namespace name; and a
  Deployment or StatefulSet with 2 or more replicas and no
  PodDisruptionBudget selecting its pods (`require-pdb`, which reads the PDBs
  live; in CI a context file stands in for the cluster). With the NodePools'
  1h `terminationGracePeriod`, a PDB slows a drain but cannot block it.
  `require-pdb` does not see the scale subresource (`kubectl scale`, HPA).
  NodePools and EC2NodeClasses are created or updated only by Argo CD's
  application controller and by Karpenter (`karpenter-config-from-git`,
  Findings #6); DELETE stays open for the teardown. Pods outside the platform
  namespaces may not tolerate the taint of pool system
  (`restrict-system-pool`, since v2.3.6; the game day probe is the one named
  exception).
- **Pool system for the platform only.** The managed node group carries the
  taint `CriticalAddonsOnly=true:NoSchedule`, the EKS convention for an add-on
  node group. Every platform workload (Argo CD, Karpenter, ESO, Kyverno and its
  hook Jobs, Alloy, kube-state-metrics, the operator from v0.14.0,
  metrics-server) selects pool system and tolerates the taint; CoreDNS and the
  node DaemonSets tolerate it by default. A workload without the toleration
  goes to the Karpenter pools. `ci/check-system-pool.py` reads every chart as
  Argo CD deploys it and fails on a platform pod that would leave the pool.
  Model replicas spread one per zone (`zoneSpread: Required`, operator
  v0.15.0, since v2.3.7): after the Spot interruption of game day #1 both had
  ended in one zone. A replica is Ready only after one real completion
  (operator v0.16.0, since v2.3.8): before, its first client paid 17 to 19 s
  of one-time cost. Game day #1 found the gap: with Karpenter down, a model replica took a
  system node ([postmortem](docs/gameday/postmortem-2026-11-20-s3.md)). Not yet
  applied live.
  Exempt, with
  the reason in the policy: `kube-system`,
  `kyverno`, and `argocd` (installed from the upstream manifest). The platform
  obeys the same rules: ESO and Alloy get starting requests, to be checked
  against usage measured live. `ci/validate-gitops.sh` runs the Kyverno CLI
  (v1.20.0, SHA-256 pinned) on ESO, Alloy and the operator rendered with the
  values ArgoCD deploys, and on fixtures that must be rejected. Applied live
  on 2026-11-15, when a privileged pod was rejected at admission; `require-pdb`
  came later and is not yet applied live.
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
  no actions and no reports, which AWS Budgets does not charge for. The tags
  come from one map (`local.tags` in `providers.tf`) and reach the Karpenter
  nodes (EC2NodeClass `spec.tags`, compared by `ci/check-cost-tags.py`) and
  the node group's instances, volumes and ENIs (launch template
  `tag_specifications`). **Cost per live session:** every resource also
  carries `Session` = the session's BUDGET entry (A-NNN), a required input of
  apply.yml and destroy.yml; the Karpenter nodes get it from a label on the
  Argo CD cluster secret through ApplicationSet `karpenter-nodes`, which
  generates no NodePool without it (fail closed). `Project` and `Session` are
  activated as cost allocation tags in `bootstrap/ci-identity`, outside the
  destroyed stack: deleting `aws_ce_cost_allocation_tag` deactivates the tag,
  so until 2026-11-23 every destroy deactivated `Project`. Operator steps:
  [cost-allocation.md](docs/runbooks/cost-allocation.md).
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
4. **Free Plan accounts have no AWS FIS.** `fis list-experiment-templates`
   answers `SubscriptionRequiredException` (2026-11-17), so creating the
   template would fail the apply; found by `scripts/verify-teardown.sh` in
   the free pre-flight, before any spend. `fis_enabled` (default false) gates
   `modules/eks/chaos.tf`; live #3 injects the Spot interruption warning on
   Karpenter's real queue instead (`tests/live/spot-interruption.sh`).
5. **vLLM CPU sizes its KV cache only from `VLLM_CPU_KVCACHE_SPACE`**
   (4 GiB by default, no CLI flag). On EKS the 6Gi pod was OOMKilled right
   after the allocation, though the same limit held in Docker; a larger
   limit did not fit because the NodePool CPU limit was reached (live #3).
   Fixed: the operator `v0.13.0` passes `spec.env` to the container and the
   workload sets 1 GiB; served on EKS in live #4.
6. **Argo CD's default diff ignores keys that Git does not declare.** A tag
   added by hand to `EC2NodeClass default` stayed, and `karpenter-nodes`
   stayed Synced with selfHeal on (live #3). Server-side diff would not
   catch it either: server-side apply leaves fields another manager owns.
   The control is at admission: `karpenter-config-from-git` lets only Argo
   CD and Karpenter create or update NodePools and EC2NodeClasses; a human
   change is audited impersonation (break-glass).
7. **The Grafana remote-write secret is created empty** and its value was
   not in the runbook: ESO and Alloy failed until it was put (live #3). Now
   step 4 of `docs/runbooks/live.md`, with a dedicated, short-lived token.
8. **Argo CD adds finalizers to a child Application with PreDelete hooks.**
   `root` stayed OutOfSync with every child Synced/Healthy (live #3 and #4).
   The diff was on `Application kyverno`: Argo CD had added
   `pre-delete-finalizer.argocd.argoproj.io` and `.../cleanup`, because the
   Kyverno chart has a pre-delete hook, and Git declares only
   `resources-finalizer`; the spec was identical. `root` now ignores exactly
   those two finalizers (jq path, with `RespectIgnoreDifferences`), so a
   missing `resources-finalizer` would still show; CI checks it
   (`ci/check-root-finalizers.py`, with a negative case).

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

    terraform init && terraform apply -var session=A-NNN  # 2 Ready nodes; A-NNN = the BUDGET entry
    aws eks update-kubeconfig --region eu-west-1 --name llm-inference
    git checkout v2.4.3                      # the release the cluster runs
    kubectl create ns argocd
    kubectl apply -k gitops/argocd --server-side  # Argo CD v3.6.2 vendored (Dex removed), SHA-256 checked in CI
    kubectl apply -f gitops/apps/projects.yaml  # first: the root app belongs to project platform
    kubectl apply -f gitops/root-app.yaml    # deploys the tag in targetRevision
    scripts/label-session.sh                 # cluster label = Session tag: Karpenter NodePools appear, nodes tagged
    terraform destroy -var session=A-NNN     # stop the meter

## Release and rollback

The cluster runs a release tag, never `main`. To promote:

1. A PR sets the new tag (`vX.Y.Z`) in every Application sourced from this
   repo; `ci/check-release-pin.py` rejects a branch or mixed tags.
2. Merge, then tag the merge commit: `git tag -a vX.Y.Z -m ... && git push origin vX.Y.Z`.
3. `git checkout vX.Y.Z && kubectl apply -f gitops/root-app.yaml`.

Rollback is the same with the previous tag.

## Verify

Every check runs offline of AWS, with no credentials, the same way in CI (`.github/workflows/ci.yml`) and locally:

    bash ci/install-tools.sh   # from inference-platform-ci v0.3.0: terraform 1.15.8, gitleaks, actionlint, helm, kubeconform, yq, openapi2jsonschema, trivy 0.76.2 (signature verified), each SHA-256 verified; PyYAML and jsonschema, every hash checked
    bash ci/validate.sh        # fmt, validate, terraform test (mock aws provider, root and bootstrap), gitleaks on full history, actionlint, trivy config, kubeconform, Kyverno CLI, AppProject kinds, release pin

Against the real AWS account, on every pull request: `terraform plan` through
GitHub OIDC (read-only role, see above).

Checked live on 2026-11-15 ([evidence](docs/evidence/live-2026-11-15.md),
runbook `docs/runbooks/live.md`): `terraform apply` and destroy from the
pipeline, Karpenter scaling to 4 Spot nodes on 2 AZs and consolidation to 0,
the NodePool CPU limit alert by email, a privileged pod rejected at
admission, requests against usage, and a clean teardown.
Checked live on 2026-11-17 ([evidence](docs/evidence/live-2026-11-17.md),
runbook `docs/runbooks/live-3.md`): a Spot interruption warning injected on
Karpenter's real queue (`tests/live/spot-interruption.sh`; AWS FIS in
`modules/eks/chaos.tf` is off on this Free Plan account), drift within the
budgets, the PDB honoured during a drain, IMDS blocked from a pod, the
NodePool cost caps, and a clean teardown. Not served: the CPU model
(Findings #5).
Checked live on 2026-11-18 ([evidence](docs/evidence/live-2026-11-18.md),
runbook `docs/runbooks/live-3.md` step 2 alone): the CPU model served through
the operator on a Karpenter Spot node, 20 answers out of 20, and a clean
teardown.

## Production gaps

Known and accepted for this project; each would be closed before production.

- One reviewer: the environments `live` and `grafana` have a single required
  reviewer, who is also the author, so a change can be self-approved.
- The apply role is broad (PowerUserAccess under a permissions boundary): to
  be narrowed with IAM Access Analyzer policy generation from the live
  session's CloudTrail.
- kustomize is pinned by SHA-256 only: its releases are not signed.
- Alloy's ClusterRole is the chart's rules minus secrets: to be narrowed to
  the resources its pipeline actually reads.
- The Grafana Cloud stack is shared with vllm-coldstart-operator. A notification
  policy replaces the whole tree, so this repository is its only owner, as
  code: severity page goes to platform-oncall-email, the rest to
  platform-email. A larger organisation would give each team its own stack or
  a central alerting repository.
- Rule changes are approved by the hash of the rules file, not by a diff
  against Grafana: the documented `/api/convert/` commands are load and sync.
- Incident response not yet practised: the live sessions proved the
  platform, not a person detecting and recovering from a failure users
  feel. Game day #1 is designed ([docs/gameday/](docs/gameday/README.md):
  SLO, three scenarios with hypotheses, roles, postmortem template, run
  sheet) and prepared since v2.3.4 (client-side probe and SLI script, the
  model at 2 replicas with its PDB, alerts `PodCrashLooping` and
  `KarpenterControllerUnavailable`); it runs after its BUDGET entry.
  Designing it found two gaps, both closed in v2.3.4: the operator creates
  no PodDisruptionBudget, so `require-pdb` denied a 2-replica model; and
  `KarpenterControllerDown` cannot fire when the controller is scaled to 0
  (no endpoint, no `up` series).
- When to run this instead of ECS Fargate, and how to move:
  [ADR 0001](docs/adr/0001-ecs-or-eks.md).
- Why an own operator and not KServe, measured on kind (same container,
  Ready 48 s and p50 about 2.2 s in both; operator control plane about 20
  times smaller, NetworkPolicy by default), and when Kueue is worth it:
  [ADR 0002](docs/adr/0002-own-operator-or-kserve.md).
- Prefix-aware routing, measured on kind in CI at zero cost: llm-d-router
  v1.0.0 with its default configuration, in front of 2 vLLM CPU v0.34.0
  replicas, against a plain Service on the same pods and load. Prefix-cache
  hit rate 0.81 against 0.54, TTFT p50 0.36 s against 0.58-0.92 s, in two
  runs; 2.1x the hit rate with 4 simulated replicas
  ([evidence](docs/evidence/prefix-routing-2026-11-23.md)). On EKS across
  two zones (live A-025): hit 0.84 against 0.52, TTFT p50 0.43 s against
  1.43 s ([evidence](docs/evidence/live-a025-2026-11-25.md)).
- Compliance: [docs/compliance-map.md](docs/compliance-map.md) maps SOC 2
  and ISO 27001 controls to evidence in this repository, with the gaps
  (no customer-managed KMS key, one reviewer, no CloudTrail trail; control-plane audit logs on since v2.3.5) and their standard fixes. A map, not a certification.
