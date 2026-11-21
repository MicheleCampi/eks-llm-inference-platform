# Dependency updates

Every version this platform runs is pinned, and every pin has an owner that
proposes its update. Nothing reaches the cluster until a maintainer merges the
update and tags a release.

## Who proposes what

| Pin | Where | Proposed by |
|---|---|---|
| Helm charts (ESO, Alloy, kube-state-metrics, Kyverno) | `gitops/apps/*.yaml` and `ci/versions.env` | Renovate, one PR per chart (both files) |
| Karpenter chart | `gitops/apps/karpenter.yaml` | Renovate |
| Operator release | `gitops/apps/vllm-coldstart-operator.yaml` | Renovate (git tags) |
| Argo CD | `ci/versions.env` CRD URLs | Renovate; manifest re-vendored by hand |
| Kyverno CLI, Prometheus image | `ci/versions.env` | Renovate |
| Images in tests and fixtures (vLLM CPU, curl, pause) | `tests/**`, `ci/fixtures/**` | Renovate (tag + digest) |
| EKS AL2023 AMI | `gitops/karpenter/ec2nodeclass*.yaml` | Renovate, monthly |
| Shared CI tools | `ci/platform-ci.env` (inference-platform-ci tag + commit) | Renovate |
| GitHub Actions | `.github/workflows/*.yml` (commit SHA) | Renovate |
| Terraform providers and lock files | `*.tf`, `.terraform.lock.hcl` | Renovate (+ monthly lock file maintenance) |
| EKS version, managed add-on versions, node group `release_version` | `main.tf`, `modules/eks/*.tf` | By hand, monthly: needs AWS credentials (below) |

`experiments/**` is not updated: an experiment records the versions it ran on.
`docs/**` is evidence and is not updated either.

## When the PR is red on purpose

Renovate changes the version string. Some pins carry more than a string, and
CI fails until the rest is done:

- chart SHA-256 in `ci/versions.env`: `helm pull <chart> --repo <url> --version <v>` then `sha256sum`;
- Karpenter: re-vendor `ci/karpenter/cloudformation-<v>.yaml` and its SHA-256 in `ci/validate.sh`;
- Argo CD: re-vendor `gitops/argocd/upstream/install-<v>.yaml`, the SHA-256 and the kustomization, and read the upgrade notes;
- AMI: set `release_version` in `modules/eks/main.tf` to the same release.

The failing check is the work order, not noise.

## vLLM

A new vLLM release changes latency. Every number in the README, the evidence
and the CV says the vLLM version it was measured on. Before citing a number on
a new version, re-run the operator's `first request after Ready on vLLM CPU`
job, and a live session only with an approved budget.

## Monthly, by hand (needs AWS)

```
aws eks describe-cluster-versions --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].[clusterVersion,endOfStandardSupportDate]' --output text
aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name vpc-cni --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion' --output text
```

Same for `eks-pod-identity-agent` and `metrics-server`, against `modules/eks/addons.tf`
and `modules/eks/karpenter.tf`.

## Majors

A major update waits for an explicit approval on the Renovate dependency
dashboard issue, and its PR says what breaks.
