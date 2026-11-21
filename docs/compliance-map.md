# Compliance map: SOC 2 and ISO/IEC 27001 controls to evidence

What this is: a map from the controls an auditor asks about to what this
repository actually does, where the evidence lives, and how to check it.
What this is **not**: an audit, a certification or a claim of compliance.
SOC 2 and ISO 27001 certify an organisation (people, HR, vendors,
policies), not a repository. A platform can only make the technical
controls true, provable and cheap to evidence. Written 2026-11-18 (D-0158,
gap G4), against release v2.3.4.

References: AICPA Trust Services Criteria 2017 (revised points of focus
2022), common criteria CC and availability A; ISO/IEC 27001:2022 Annex A.
Status: **done** (in the code and checked by CI or proven live),
**partial** (in the code, not proven, or proven only in part), **gap**
(missing; listed with the standard fix).

## Access control

| Control | What the platform does | Evidence | Check | Status |
|---|---|---|---|---|
| CC6.1, A.5.15, A.8.2 (least privilege, privileged access) | Every IAM role carries a permissions boundary; CI roles are separate for plan (read-only) and apply | `bootstrap/ci-identity/apply.tf`, `modules/eks/*.tf` (`permissions_boundary`) | CI `ci/check-iam-boundary.py` | partial: the apply role is PowerUserAccess under the boundary (README, Production gaps) |
| CC6.1, A.5.17, A.8.5 (no long-lived credentials) | GitHub OIDC to AWS STS, no stored keys; pods get AWS access through EKS Pod Identity | `.github/workflows/*.yml` (`id-token: write`), `modules/eks/karpenter.tf`, `modules/eks/eso.tf` | `gitleaks git` in `ci/validate.sh` | done |
| CC6.1, A.8.5 (cluster authentication) | EKS access entries (`authentication_mode = "API"`), no aws-auth ConfigMap | `modules/eks/main.tf` | `tests/access_entries.tftest.hcl` | done |
| CC6.6, A.8.20, A.8.22 (network boundary) | Private subnets for nodes; public API endpoint limited to declared CIDRs, `0.0.0.0/0` rejected by validation | `modules/vpc`, `modules/eks/variables.tf` | `tests/public_access_cidrs.tftest.hcl` | done |
| CC6.6, A.8.22 (segmentation inside the cluster) | VPC CNI network policy on; the operator gives each model a default-deny NetworkPolicy that admits only labelled clients | `modules/eks/addons/vpc-cni.json`, operator `build_network_policy` | probe of live #5 (client label) | partial: in the code, not yet proven live on EKS (the game day probe is the first labelled client) |
| A1.2, A.8.14, A.8.22 (platform capacity kept apart from workloads) | Pool system tainted `CriticalAddonsOnly`; every platform workload tolerates it and selects it; Kyverno denies the toleration to other namespaces | `modules/eks/main.tf` (`taint`), `gitops/apps/*.yaml`, `gitops/argocd/kustomization.yaml`, `gitops/policies/restrict-system-pool.yaml` | `tests/addons.tftest.hcl`, CI `ci/check-system-pool.py` and Kyverno fixtures with negative cases | partial: in the code since v2.3.6, re-run of game day S3 pending ([postmortem](gameday/postmortem-2026-11-20-s3.md)) |
| CC6.8, A.8.7 (workload hardening) | IMDSv2 required, hop limit 1, so pods cannot reach node credentials; Kyverno denies privileged pods | `modules/eks/main.tf` (`metadata_options`), `gitops/policies/disallow-privileged.yaml` | live #3: `IMDS BLOCKED` ([evidence](evidence/live-2026-11-17.md)); privileged pod rejected at admission ([evidence](evidence/live-2026-11-15.md)) | done |
| A.5.18 (access review) | One reviewer, who is also the author | GitHub environments `live`, `grafana` | none | gap: needs a second person; standard fix is two required reviewers and a quarterly access review |

## Change management and secure development

| Control | What the platform does | Evidence | Check | Status |
|---|---|---|---|---|
| CC8.1, A.8.32 (change control) | `main` protected; every change by pull request with CI; releases are annotated tags the maintainer creates only after CI is green on the merge commit; Argo CD Applications pin a release tag, never a branch | `gitops/root-app.yaml`, `gitops/apps/*.yaml` | CI `ci/check-release-pin.py` (rejects `main`) | done |
| CC8.1, A.8.32 (approval before production change) | `terraform apply` and `destroy` only by manual dispatch behind an environment approval; the approved plan is bound by the SHA-256 of its resource changes | `.github/workflows/apply.yml`, `destroy.yml` | the apply job refuses a plan whose hash differs | done |
| CC8.1, A.8.9 (configuration drift) | Argo CD self-heal; Kyverno lets only Argo CD and Karpenter change NodePools and EC2NodeClasses (out-of-band edits were not reverted, live #3) | `gitops/policies/karpenter-config-from-git.yaml` | CI Kyverno negative cases | done |
| CC7.1, A.8.8 (vulnerabilities in configuration) | trivy config on Terraform, manifests and rendered charts, HIGH and CRITICAL fail the build | `ci/validate-gitops.sh` (`trivy-config`, `trivy-charts`) | CI | done |
| CC7.1, A.8.8 (vulnerabilities in images) | Images pinned by digest; Kyverno rejects `:latest` and untagged images; every image the platform runs (charts as deployed, test workloads) scanned by trivy on each PR that can change one and weekly; a fixable CRITICAL fails, HIGH is reported; exceptions only with a reason and an expiry | `gitops/policies/disallow-latest-tag.yaml`, `ci/image-scan.sh`, `.github/workflows/image-scan.yml`, `ci/trivyignore-images.yaml` | workflow `image-scan` | partial: the first scan (2026-11-18) found fixable CRITICALs in Argo CD 3.4.3, the Dex and Redis it ships, and the vLLM CPU test image. Fixed: Dex removed (SSO unused); Argo CD upgraded to 3.4.14, then 3.5.8: from 5 to 3 to 1 CRITICAL, the last in the kustomize binary it bundles. Still baselined until 2026-12-18 in `ci/image-scan-baseline.txt`, each with its fix: Argo CD 3.5.8 (fix: a patch that rebuilds kustomize), Redis (same version in 3.4.14) and the vLLM CPU test image. EKS add-on images are patched by AWS, out of scope |
| CC8.1, A.8.25, A.8.28 (secure supply chain of the pipeline) | Every CI tool pinned by SHA-256; GitHub Actions pinned by commit; Dependabot weekly | `ci/platform-ci.env`, `.github/workflows/*.yml`, `.github/dependabot.yml` | `actionlint`, install script checks hashes | done |
| A.8.31 (separation of environments) | Plan environments separate from apply environments; a single live environment | `.github/workflows/*.yml` | none | partial: one cluster, no staging; standard fix is a staging cluster or ephemeral per-PR environment |

## Secrets and data protection

| Control | What the platform does | Evidence | Check | Status |
|---|---|---|---|---|
| CC6.1, A.5.33, A.8.24 (secrets) | Secrets in AWS Secrets Manager, synced by External Secrets; none in Git; account id masked from every CI log | `modules/eks/eso.tf`, `gitops/monitoring/grafana-secret.yaml` | `gitleaks`, CI `ci/check-account-mask.py` with a negative case | done |
| A.8.24 (encryption at rest) | Kubernetes secrets: EKS default envelope encryption (AWS-owned key) | none in this repository | none | gap: no customer-managed KMS key; standard fix is `encryption_config` with a CMK and key rotation |
| A.8.12 (data leakage to AI tools) | Public rules for what may go to an AI agent; logs masked before they are pasted | [How I work with AI](https://github.com/MicheleCampi/llm-inference-platform/blob/main/docs/how-i-work-with-ai.md) | review | done for this project |

## Logging, monitoring and incident response

| Control | What the platform does | Evidence | Check | Status |
|---|---|---|---|---|
| CC7.2, A.8.16 (monitoring) | 10 alert rules in Prometheus format, unit-tested; every metric they use is checked to be shipped | `observability/karpenter-rules.yaml`, `.test.yaml`, `ci/metrics-shipped.py` | promtool in CI | done |
| CC7.2, A.8.15 (audit logging) | EKS control-plane logs api, audit and authenticator to CloudWatch Logs, in a log group Terraform owns with 7-day retention, removed by destroy | `modules/eks/main.tf` (`enabled_cluster_log_types`, `aws_cloudwatch_log_group.control_plane`) | `tests/control_plane_logs.tftest.hcl`; `scripts/verify-teardown.sh` (no log group left); game day #1 (live #5) | partial: proven live in game day #1 (2026-11-20: the S2 change and its rollback reconstructed from the audit log, [evidence](evidence/gameday-2026-11-20.md#audit-trail-eks-control-plane-audit-log-cloudwatch-logs)); no organisation CloudTrail trail or VPC flow logs managed here (standard fix: an organisation trail, flow logs on the VPC) |
| CC7.3, CC7.4, A.5.24 to A.5.27 (incident response and learning) | Runbook per alert; paging by severity; game day with blameless postmortems designed and prepared | `docs/runbooks/`, `docs/gameday/` | game day #1 (live #5) | partial: designed, not yet run |
| CC7.5 (recovery) | The whole platform is reproducible from Git: apply from the tag, GitOps bootstrap, verified teardown | `docs/runbooks/live.md`, `scripts/verify-teardown.sh` | four live sessions, each `TEARDOWN CLEAN` | done |

## Availability and capacity

| Control | What the platform does | Evidence | Check | Status |
|---|---|---|---|---|
| A1.1, A.8.6 (capacity) | Karpenter NodePools with CPU limits as cost caps; GPU pool gated at 0 | `gitops/karpenter/` | CI `ci/check-nodepools.py`; live #3: limit refused a node | done |
| A1.2, A.8.14 (resilience) | Spot interruptions handled through the real SQS queue; PDBs required for 2 or more replicas; disruption budgets for drift | `gitops/policies/require-pdb.yaml`, `gitops/karpenter/nodepool-general.yaml` | live #3: replacement Ready in 53 s, PDB never below 0 | done |
| A1.2 (objectives) | SLO and error budget for the served model | `docs/gameday/README.md` section 1 | game day #1 | partial: defined, measured only in the game day |
| CC3.2, CC9.1 (cost risk) | AWS Budget and cost-allocation tags as code; every live session has a cap approved before apply and a forced destroy deadline | `modules/budget/`, `ci/check-cost-tags.py` | real cost from Cost Explorer per session | done |

## Summary and order to close the gaps

| Gap | Standard fix | Cost |
|---|---|---|
| CloudTrail trail and VPC flow logs (CC7.2, A.8.15) | organisation trail to a locked S3 bucket; flow logs on the VPC | first trail free for management events; flow logs per GB |
| Customer-managed KMS key (A.8.24) | `encryption_config` with a CMK, rotation on | ~1 USD a month per key while it exists |
| Second reviewer and access review (A.5.18) | two required reviewers on `live` | needs a second person |
| Staging (A.8.31) | ephemeral cluster per release | doubles live cost; not worth it at this scale |

What an auditor would still need that no repository can give: written
policies, risk assessment, HR and vendor management, evidence collected
over a period (SOC 2 Type II covers months, not a session).
