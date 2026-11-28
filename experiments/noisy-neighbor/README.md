# Noisy neighbor: a separate premium pool against a shared pool, on kind

Written 2026-11-28, before any code or run. Results go to
`docs/evidence/noisy-neighbor-<date>.md`; this file is not edited to fit
them. Any change after the first run is a dated amendment at the end.

## Question

"Two teams share your inference platform. The batch team sends a burst.
What happens to the premium team's SLO, and what stops it?" ROADMAP step 7b.

Step 9 (`experiments/finops-guardrail`, D-0176) answered half of it: inside
one pool, priority admission in the router did not keep premium inside its
SLO above capacity, because the contention is inside vLLM (two requests on
one replica share its cores) and a router can only decide who waits. The
standard answer to noisy neighbors is isolation *between* pools, not
priority *inside* one: the premium tenant gets its own replicas on its own
nodes, and the platform makes that boundary hold in the API, not by
convention. This experiment measures that answer and checks its guardrails:

1. With the same hardware and the same traffic, does a separate premium
   pool keep premium inside its SLO while batch bursts, where a shared pool
   does not?
2. What does it cost? EUR per million good tokens, each tenant against its
   own SLO, same pool size in both arms.
3. Do the tenancy guardrails hold, each checked by a request that must be
   refused: NetworkPolicy, ResourceQuota, the premium pool's taint, and the
   admission policy that keeps other tenants from tolerating it?
4. Does Kueue hold the batch tenant's Jobs to its quota?

## Standard first

Nothing custom decides isolation. Every control is a Kubernetes or
Kubernetes SIG API, versioned as YAML:

| Enterprise requirement | Control here | Standard |
|---|---|---|
| a namespace per tenant, limits per tenant | `ResourceQuota`, `LimitRange`, `Role` read-only on its own limits (pattern of `gitops/tenants/demo` and gke `tenants/b`) | core API |
| a tenant cannot reach another tenant's model | `NetworkPolicy` default deny in each tenant namespace, and per-pool ingress rules on the serving pods | core API, enforced by kindnet (kind v0.33) |
| premium has its own nodes | node label `pool=premium` and taint `pool=premium:NoSchedule` (on EKS: a Karpenter NodePool with the same taint) | core API |
| no other tenant can tolerate that taint | a `ValidatingAdmissionPolicy` (CEL): a pod that tolerates `pool=premium`, or every taint, is refused unless its namespace is labelled `platform.michelecampi.dev/premium-pool: allowed`; tenants cannot label namespaces (their Role has no verb on namespaces) | core API, GA since 1.30; eks does the same for the system pool with Kyverno |
| batch Jobs wait for quota instead of piling on | Kueue v0.20.8 (latest release, read 2026-11-28): `ClusterQueue` with a CPU quota for the batch tenant, `LocalQueue` in its namespace | kubernetes-sigs |

Kueue manages **Jobs**, not the Deployments that serve the model: it is the
batch tenant's client (an offline inference Job) that queues for quota, not
the vLLM replicas. That is how Kueue is meant to be used, and it is said
here so that nobody reads it as "Kueue isolates serving".

## Set-up

- kind v0.33.0, Kubernetes v1.36.4, on a GitHub-hosted runner (4 CPUs),
  four nodes: the control plane, `pool=system` (clients, Kueue, calibration),
  `pool=premium` (tainted), `pool=batch`.
- The step 7 serving set-up: vLLM CPU v0.34.0, Qwen2.5-0.5B-Instruct at the
  pinned commit, default KV cache, `--max-model-len 2048`. **Two replicas,
  the same two pods in both arms**: `model-premium` on the premium node,
  bound to cores 0-1, and `model-batch` on the batch node, bound to cores
  2-3, both in the platform's serving namespace `bench`. On kind every node
  is a container on the same host, so the node boundary alone does not
  separate CPU; the core binding does, and it is the same in both arms. The
  runner checks of step 8 (AVX-512, AMX on Intel).
- Two tenant namespaces, `tenant-premium` and `tenant-batch`. Each tenant's
  client runs in its own namespace, so every request crosses the
  NetworkPolicies as a tenant's request would. The premium client is a Pod;
  the batch client is a Job admitted by Kueue.

## Arms

| Arm | Premium requests go to | Batch requests go to | Serving NetworkPolicy |
|---|---|---|---|
| `shared` | Service `model`: both replicas | Service `model`: both replicas | both pods accept both tenants |
| `isolated` | Service `model-premium`: its replica only | Service `model-batch`: its replica only | each pod accepts only its own tenant |

The difference between the arms is two NetworkPolicies and the URL each
client is given, nothing else: same pods, same cores, same cost.

Sequence in one job, on one runner: calibrate T, P and C with the step 7
code and rules (through Service `model`, both replicas), the guardrail
checks (H3, H4), then `shared` rep 1, `isolated` rep 1, `isolated` rep 2,
`shared` rep 2. Two jobs, the second in the reverse arm order. Every
comparison stays inside one job.

## Traffic

The `conv` window of step 7 (same pinned CSV, same 20 minutes around the
busiest minute, lengths divided by 8), at a mean of **1.5 x C**, as step 9
amendment 2, so that at the peak the offered load is above what the pool
serves inside the SLO. Each request is assigned to **premium with
probability 0.2** and to batch otherwise (fixed seed, the step 9 code), so
both arms replay the same requests with the same tenants. The premium
tenant's mean is then 0.3 x C, which is 0.6 x the capacity of one replica if
the two replicas are equal (C / 2 each): the premium pool is sized for
premium by the step 7 rule (replay at 0.6 x capacity), and the burst is
batch's. The 20/80 mix is a choice made so, fixed here, not a measurement.

Both clients start at the same wall-clock second (`--start-at`) and send
only their own tenant's requests (`--only-tenant`) from the same schedule.

## SLOs, cost and measures (fixed here, as step 9)

- **Premium SLO:** HTTP 200, TTFT <= T and TPOT <= P. Objective 99 %.
  T = 2 x TTFT p95 and P = 2 x TPOT p95, one request at a time, this runner.
- **Batch SLO:** HTTP 200, TTFT <= 10 x T and TPOT <= 2 x P. Objective 95 %.
- **Error budget burned:** per tenant, bad / requests over the replay,
  divided by the budget (1 % premium, 5 % batch).
- **Cost:** step 7 reference price, 0.2134 USD/h for the 4 vCPU of the two
  replicas, at the EUR rate printed in the report; the same in both arms.
  **EUR per million good tokens** = cost of the window / good tokens of
  both tenants, each against its own SLO (step 9's `report.py`).

## Hypotheses

| # | Hypothesis |
|---|---|
| H1 | premium protected: in each job, the premium budget burned in `isolated` is at most half that of `shared` (median of two reps against median of two reps), and at most 100 % in every `isolated` rep |
| H2 | no waste: in each job, EUR per million good tokens in `isolated` is at most 1.1 x that of `shared` (medians) |
| H3 | guardrails hold, in each job, all of: (a) a pod in `tenant-batch` cannot open a TCP connection to the premium replica, and can to its own, in the `isolated` configuration; a pod in `tenant-premium` can reach the premium replica; (b) a pod in `tenant-batch` asking more CPU than its ResourceQuota is refused by the API server; (c) a pod in `tenant-batch` that selects the premium node without the toleration is never scheduled (FailedScheduling, untolerated taint); (d) a pod in `tenant-batch` that tolerates the premium taint, by key or by `operator: Exists` with no key, is refused by the admission policy, and the same pod in `tenant-premium` is admitted |
| H4 | Kueue holds batch to its quota: of two batch Jobs submitted together whose requests fit the ClusterQueue only one at a time, the second has no pod until the first finishes, and then runs |

A refuted hypothesis is published as refuted. Expectation, written so that
it can be wrong: H1 holds, H2 is uncertain (batch loses half the pool, and
its good tokens may fall by more than premium gains), H3 and H4 hold.

## What this does not show

- A GPU pool or real tenants. On GPUs the argument is stronger (a GPU is not
  shared between replicas at all without MIG or time-slicing), but no GPU
  number comes from here.
- CPU isolation by the node boundary: on kind it comes from the core
  binding (see Set-up). On EKS the same YAML puts the premium pool on its
  own instances.
- The right size of the premium pool: one replica, by the 0.6 x rule, with
  C / 2 per replica assumed, not calibrated per replica.
- The router: both arms go through kube-proxy Services. Step 9 measured
  priority in the router on a shared pool; the two answers can be combined.
- Spare capacity: in `isolated` the premium replica idles when premium is
  quiet and batch cannot use it. That is what H2 prices.
- Fairness among several batch tenants (Kueue cohorts, borrowing): one
  batch tenant only.
