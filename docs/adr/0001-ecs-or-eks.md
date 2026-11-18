# ADR 0001: When a team on ECS Fargate should move to EKS, and how

- Status: proposed (2026-11-18, D-0158); accepted when merged
- Context repositories: [aws-ecs-delivery-platform](https://github.com/MicheleCampi/aws-ecs-delivery-platform)
  (ECS Fargate) and this one (EKS with Karpenter, Argo CD, Kyverno). Same
  author, same AWS account, same rules (Terraform, keyless CI, approval
  before apply, verified teardown), so the comparison is like for like.

## Context

Many teams start on ECS Fargate and later ask whether to move to Kubernetes.
The question is usually framed as "which is better". It is the wrong
question: each is the better choice for a different shape of organisation.
This ADR writes the criteria down, with the costs measured on these two
platforms, and the migration path that was proven between them.

## Measured facts (from the two repositories)

| | ECS Fargate | EKS + Karpenter |
|---|---|---|
| What ran | one stateless HTTP service, ALB + Cognito, DEV/QA/PROD by image digest | platform layer (Argo CD, Karpenter, Kyverno, ESO, Alloy) and a model served by an operator |
| Gross spend, before credits | 2.04 USD for the whole project, June to November 2026 | 1.344 USD for 14-15/11 (A-016), 1.438 USD for live #3, 1 h 45 min (A-017); live #4 from Cost Explorer (A-018) |
| Fixed cost while running | none beyond the tasks, ALB and NAT | control plane 0.10 USD per hour (about 73 USD a month) plus 2 On-Demand system nodes, before any workload |
| Time from apply to serving | minutes (task + ALB health check) | ~11 min apply, ~4 min GitOps, 118 s for the model to be Ready (live #4) |
| Things the team operates | task definitions, service, ALB | cluster upgrades (EKS standard support about 14 months per version), add-ons, Karpenter, Argo CD, Kyverno, observability agents |
| Same image on both | yes: the ECS production image by digest answered 60/60 on EKS (A-016) | |

Sources: aws-ecs README "Cost" and "Evidence" (A-015, A-016); this
repository's `docs/evidence/` and README; platform-notes BUDGET A-016 to
A-018.

## Decision

Stay on ECS Fargate while **all** of these hold:

1. Fewer than about 10 services, owned by one or two teams.
2. Stateless HTTP or queue workers; no GPU or accelerator scheduling.
3. No need for operators or custom resources (model serving, databases,
   job queues managed in-cluster).
4. Policy needs met by IAM, SCPs and CI checks, without admission control.

Move to EKS when **any** of these becomes true, because ECS has no
equivalent and building one costs more than running Kubernetes:

1. **GPU or accelerator workloads**: device plugins, bin-packing on
   expensive nodes, Spot with interruption handling, scale to zero on GPU
   (Karpenter pools with limits; this repository).
2. **A platform for several teams**: namespaces, quotas, a self-service
   contract (a VllmService instead of a ticket), GitOps per team.
3. **Policy as code at admission**: required requests, PDBs, no latest
   tags, no privileged pods (Kyverno, enforced here).
4. **Portability as a requirement**: the same manifests on GKE and EKS
   (proven by the GKE twin of this platform).

Fargate stays the right home for the services that do not need the above,
even after the move: a hybrid estate is a valid end state, not a failure.

## Migration path (for the move, when it happens)

1. **Platform first, empty**: EKS with GitOps, policies, observability and
   cost guardrails (budgets, NodePool limits) before any service moves.
   Cost of an idle platform measured and accepted in the budget.
2. **Same artefact**: move the image by digest, not a rebuild; prove it
   with a probe from outside (A-016: 60/60).
3. **Shadow, then weighted traffic**: ALB weighted target groups or DNS
   weights, 1 % → 10 % → 50 % → 100 %, each step gated by the service's
   SLO on the new side; ECS stays deployed.
4. **Rollback at every step**: weights back to ECS; nothing is deleted on
   ECS until 100 % has held for an agreed period (one release cycle).
5. **Decommission** ECS resources with the same verified-teardown check.

## Consequences

- EKS costs money while idle; ECS mostly does not. For a small estate the
  fixed EKS cost and the operating load are the dominant line, not compute.
- EKS buys capabilities (GPU, operators, admission policy, multi-tenancy)
  that a growing platform needs; buying them early is waste, buying them
  late is a rushed migration.
- Not measured here: a weighted cut-over under real traffic (the A-016 test
  was a probe, not a migration), and the people cost of upgrades over a
  year. Both are stated as limits, not assumed.
