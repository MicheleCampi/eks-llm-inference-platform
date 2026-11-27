# ADR 0003: Canary with automatic rollback on the SLO: which tool

- Status: proposed (2026-11-27, ROADMAP step 8, platform-notes D-0172);
  accepted when the evidence of `experiments/canary-rollback` is merged
- Revises the canary trigger of [ADR 0002](0002-own-operator-or-kserve.md),
  decision 2

## Context

The question a reviewer asks after "why not KServe?" is "how do you ship a
new model version without downtime, and who stops a bad one?". Today the
platform's operator (vllm-coldstart-operator v0.18.0) owns a Deployment with
`RollingUpdate`, `maxSurge 1`, `maxUnavailable 0`: no request is dropped by
design, but a version that is healthy and slow reaches 100 % of the pods,
and only a person stops it.

ADR 0002 listed "canary rollout or traffic splitting between model versions
is needed" as a trigger to adopt KServe. The need is now here, so the trigger
is checked against what KServe's canary does.

## Options

| Option | Automatic analysis and rollback | Fits this platform | Cost to adopt |
|---|---|---|---|
| **KServe canary** (`canaryTrafficPercent`) | no: promotion and rollback are manual, by editing the percentage; **Serverless (Knative) mode only** (KServe 0.21 docs, read 2026-11-27) | no Knative here; KServe itself is the exit path of ADR 0002, not adopted | KServe + Knative + a separate analysis loop |
| **Argo Rollouts** (CNCF, Argo project) | yes: AnalysisTemplate on Prometheus, abort scales the canary to 0 | Argo CD already deploys the platform; Rollout is a drop-in for a Deployment, or references one (`workloadRef`) | one controller, CRDs; Prometheus is already in the stack |
| **Flagger** (CNCF, Flux project) | yes: metric analysis, rollback | built around Flux and a mesh or ingress for the split | a second GitOps family next to Argo CD |
| **Logic in the operator** | only what we write | the operator already owns the Deployment | analysis, state machine and abort written and maintained by one author: re-implementing a CNCF tool |

## Decision (proposed)

1. **Argo Rollouts** for canary with analysis, with an AnalysisTemplate on
   Prometheus that reads the SLO of the model server (TTFT under the SLO
   threshold, as a burn rate against the 99 % objective). It is the standard
   next to Argo CD and the smallest addition that gives an automatic rollback.
2. **ADR 0002, decision 2, revised:** the canary need alone is no longer a
   trigger for KServe. KServe's canary is manual and needs Knative; KServe
   stays the exit for many runtimes, disaggregated serving with llm-d and an
   employer standard.
3. **Not the operator:** the operator keeps what it is measured for (warm
   Ready, make-before-break drain). It does not grow its own canary engine.

The measured part (zero downtime, time to abort, budget saved against the
operator's rolling update, no false rollback) is the experiment's evidence;
this ADR is accepted only if H1 and H2 there hold.

## Consequences

- **The operator and Argo Rollouts must not both own the replicas.** With
  `workloadRef`, Argo Rollouts scales the referenced Deployment down and
  creates its own ReplicaSets; the operator, which reconciles
  `spec.replicas` on its Deployment, would scale it back. The fix is an
  opt-in field in `VllmService` (for example `rollout: external`) under
  which the operator keeps creating the Deployment and its NetworkPolicy
  but leaves replicas to Argo Rollouts. That is an operator change, its own
  PR and tag, after this evidence.
- The canary split without a traffic router is the ratio of pods: with 2
  replicas the smallest step is 50 %. Finer steps need the Gateway API
  plugin of Argo Rollouts or the llm-d router; not needed for 2 replicas.
- Analysis on a low-traffic canary is noisy (a dozen requests in 2
  minutes); the burn-rate threshold is a page threshold, not a test.
- One more controller to keep current (Renovate pin, as every chart here).
