# FinOps guardrail at the peak: priority admission in llm-d-router, on kind

Written 2026-11-27, before any code or run. Results go to
`docs/evidence/finops-guardrail-<date>.md`; this file is not edited to fit
them. Any change after the first run is a dated amendment at the end.

## Question

"What do you do when a burst arrives and you do not want to pay for more
GPUs?" There are two answers. You buy capacity for the peak and pay for it all
day, or you decide in advance who waits. ROADMAP step 9 asks for the second
one, written as a policy: under the busiest minutes of the replayed Azure
trace (`experiments/trace-replay`, ROADMAP step 7), on a fixed pool:

1. Does admission by priority keep the premium tenant inside its SLO while
   the batch tenant absorbs the burst?
2. What does it cost? EUR per million good tokens, every tenant counted
   against its own SLO, against the same pool with no policy.
3. Is the degradation declared? A held-back request is answered with a
   status code the client can act on, never a silent timeout or a 5xx.

## Standard first

No custom code decides admission here. llm-d-router v1.0.0, the release
this platform already runs (D-0165, D-0169), ships the Gateway API Inference
Extension **flow control** layer:
- it is behind the `flowControl` feature gate, off by default;
- a request's priority comes from its `InferenceObjective`, named by the
  `x-llm-d-inference-objective` header;
- the `priority-holdback-policy` gives each priority an admission ceiling
  against pool saturation;
- requests of negative priority are *sheddable*: they wait in the EPP for
  at most a TTL, then are rejected with 429.

The guardrail is that configuration, versioned in Git (a Helm values file),
and the experiment measures it.

| Enterprise requirement (ROADMAP step 9) | How it is met |
|---|---|
| opt-in per tenant | one `InferenceObjective` per tenant; a client with no header gets priority 0 |
| SLO as the limit | the premium SLO is the hypothesis under test (H1) |
| degradation declared in the response | 429 for a shed request; the response header `x-llm-d-flow-queue-duration-ms` for queue time |
| every decision logged | the EPP's flow control metrics and logs, saved per run |
| rollback with a flag | remove the feature gate from the values file; Argo CD reverts it like any other change |

Not standard, and not built here: a loop that reads *cost* from Prometheus
and changes the policy by itself. The saturation detector reads pool
utilization. Utilization is the cost driver of a fixed pool, so the policy
is set by price once: the pool size is the budget. A cost-driven controller
would be a later step, and only if this one misses H1 or H2.

## Set-up

- kind on a GitHub-hosted runner (4 CPUs), the step 7 set-up: vLLM CPU
  v0.34.0, Qwen2.5-0.5B-Instruct at the pinned commit, 2 replicas of 2 cores,
  `--max-model-len 2048`, default KV cache. The same runner checks as step 8:
  AVX-512, and AMX on Intel (`experiments/canary-rollback`, amendment 3).
- llm-d-router v1.0.0 (`llm-d-router-standalone` chart) **with an
  InferencePool**, so that the EPP watches InferenceObjectives. In the
  chart's standalone mode without a pool it does not watch them, and every
  request gets the default priority (`cmd/epp/runner/runner.go`). The
  InferencePool CRD (Gateway API Inference Extension) and the
  InferenceObjective CRD (llm-d.ai) are applied from pinned files.
  Scorers are the chart defaults, and the Envoy upstream idle timeout is 4 s
  (D-0170).
- Two tenants. Each request of the replay is assigned to **premium** with
  probability 0.3 and to **batch** otherwise, with a fixed seed, so both arms
  replay the same requests with the same tenants. Lengths come from the
  trace for both, unchanged.

## Arms

| Arm | Router config | Premium | Batch |
|---|---|---|---|
| `nopolicy` | chart defaults, flow control off, no InferenceObjective | priority 0 | priority 0 |
| `guardrail` | `flowControl` gate on, the chart's scorers unchanged; `priority-holdback-policy` with explicit ceilings 10 -> 1.0 and -10 -> 0.6; `defaultRequestTTL` = the batch TTFT limit (10 x T); band 10 with TTL `0s`, so premium is queued but never shed | objective `premium`, priority 10 | objective `batch`, priority -10 (sheddable) |

Both arms send the objective header, and in `nopolicy` it names nothing.
The difference between the arms is the values file, and nothing else.

Sequence in one job, on one runner (step 8, amendment 2): calibrate T, P
and C with the step 7 code and rules (through the Service, one request at a
time for T and P, the Poisson ladder for C). Then `nopolicy` rep 1,
`guardrail` rep 1, `guardrail` rep 2, `nopolicy` rep 2. Two jobs, the second
in the reverse arm order. Every comparison stays inside one job.

## Traffic

The `conv` window of step 7 (same pinned CSV, same 20 minutes around the
busiest minute, lengths divided by 8), thinned to **0.6 x C** as in step 7.
At that load the bursts already broke the SLO on the router in step 7
(914 % of the budget burned on conv), so the peak is real and there is
something to protect.

## SLOs, cost and measures (fixed here)

- **Premium SLO:** as step 7. A request is good if HTTP 200, TTFT <= T and
  TPOT <= P. Objective 99 %, T = 2 x TTFT p95 and P = 2 x TPOT p95,
  one request at a time, on this runner.
- **Batch SLO:** a request is good if HTTP 200, TTFT <= 10 x T and TPOT <= 2
  x P. Objective 95 %. A 429 is bad for batch. It is declared, but the
  tokens were not served.
- **Error budget burned:** per tenant, the fraction of bad requests over the
  replay, divided by the tenant's budget (1 % premium, 5 % batch).
- **Cost:** the step 7 reference price (0.2134 USD/h for 4 vCPU of
  replicas), converted at the rate printed in the report. The pool is the
  same in both arms, so the cost of the window is the same in both arms.
  **EUR per million good tokens** = cost of the window / (premium good
  tokens + batch good tokens), each tenant against its own SLO. This is the
  FinOps number: a policy that does not add capacity can only win by turning
  more of the same spend into good tokens, or by putting the spend where the
  SLO is.
- **Declared degradation:** responses per tenant by class (200, 429, other
  HTTP, connection error, timeout), and the queue time header when present.

## Hypotheses

| # | Hypothesis |
|---|---|
| H1 | premium protected: in each job, the premium budget burned in `guardrail` is at most half that of `nopolicy` (median of the two reps against the median of the two reps), and at most 100 % in every `guardrail` rep |
| H2 | no waste: in each job, EUR per million good tokens in `guardrail` is at most 1.1 x that of `nopolicy` (medians) |
| H3 | declared: in every `guardrail` rep, 0 premium requests get a non-200 response, and every non-200 batch response is a 429 (no 5xx, no connection error, no client timeout) |

A refuted hypothesis is published as refuted.

## What this does not show

- A GPU pool, real tenants, or a gateway in front: the client talks to the
  chart's Envoy directly, as in steps 5 and 7.
- A cost-driven controller (see "Standard first"), or scaling out. The
  counterfactual "add a third replica for the peak" does not fit a 4-CPU
  runner and is priced in the report, not run.
- Fairness among tenants of the same priority: one tenant per priority.
- The tenant mix: 30/70 is a choice, fixed here, not a measurement.

## Amendment 1 (2026-11-27, after run 1)

Run 1 (runs 46052787808 job 1 and 46052881592, evidence in
`docs/evidence/finops-guardrail-2026-11-27.md`) is published as recorded:
H1 refuted, H2 and H3 held. But the guardrail **never engaged**: no batch
request was held or shed (0 responses 429 in four `guardrail` reps), and the
queue time header read 0 ms at p95. The cause is the saturation signal,
not the policy. The chart's default detector (`utilization-detector`) scores
each pod as max(waiting queue / 5, KV cache use / 0.8). vLLM's default
`--max-num-seqs` admits every request into the running batch, so the waiting
queue stays at 0, and 1 GiB of KV cache per replica is nearly empty with
these lengths. The pool read as idle while two requests sharing one 2-core
replica broke the premium SLO (premium burned 308 % to 1462 % of its
budget in `nopolicy`).

The change, still configuration of llm-d-router v1.0.0 and nothing else:
- `flowControl.saturationDetector` is the **`concurrency-detector`**
  (upstream, `requests` mode): saturation = requests in flight / declared
  capacity. The capacity is **1 request per replica** (`maxConcurrency: 1`,
  headroom 0). That is the concurrency at which one replica meets the
  premium SLO here: one at a time, T and P hold by definition; run 1 shows
  that two on one replica do not. Declaring capacity in requests is the
  enterprise form of "the pool size is the budget".
- The batch ceiling goes from 0.6 to **0.5**. With two slots, saturation
  takes the values 0, 0.5 and 1, so 0.6 would admit batch exactly as far as
  premium. At 0.5 batch is dispatched only into an empty pool, and one slot
  stays for premium. Premium keeps 1.0.
- Everything else is unchanged: the `nopolicy` arm, the vLLM pool (same
  replicas, same flags, so the same cost), calibration, load 0.6 x C, TTL
  10 x T, tenants, SLOs, hypotheses and thresholds.

A queued premium request now waits in the EPP instead of sharing a replica,
and its TTFT includes that wait. That is the trade H1 measures.

## Amendment 2 (2026-11-27, after run 2)

Run 2 (run 46064579619, amendment 1) is published as recorded in the
evidence file: the guardrail engaged (batch queued in the EPP, queue time
p95 2.0 to 3.3 s) and H1 was refuted again, H2 and H3 held. At 0.6 x C there
is no peak above capacity. Each rep holds 130 premium requests (67 on the
slower runner), so the premium budget of 1 % is 1.3 requests, and two reps
of the same arm in one job differed by up to 3.5 times (538 % and 154 %).
Batch never reached its TTL, so the 429 path was not exercised with vLLM.

ROADMAP step 9 asks about a burst that the pool cannot absorb. The change:
- the replay's mean rate is **1.5 x C** instead of 0.6 x C (`LOAD_X` in
  `run.sh`), thinned from the same window with the same seed. C is
  calibrated as before, so at the trace's peak the offered load is above
  the rate at which the pool meets the SLO;
- everything else is unchanged: both arms, amendment 1, TTL, tenants, SLOs,
  hypotheses and thresholds.

Runs 1 and 2 stay in the evidence. The verdict of ROADMAP step 9 is the
one of run 3, with runs 1 and 2 next to it.
