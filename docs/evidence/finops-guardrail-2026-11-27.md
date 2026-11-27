# Experiment evidence: FinOps guardrail at the peak, on kind (2026-11-27)

Protocol and hypotheses: [`experiments/finops-guardrail/README.md`](../../experiments/finops-guardrail/README.md),
written before any run. Amendment 1 came after run 1, and amendment 2 after
run 2. Both are dated and change only the saturation signal (1) and the
offered load (2). Workflow: `.github/workflows/finops-guardrail.yml`. Cost: 0
(GitHub-hosted runners, no AWS resources).

Set-up, as in the protocol: kind on a 4-CPU runner, 2 vLLM CPU v0.34.0
replicas of 2 cores (Qwen2.5-0.5B-Instruct), llm-d-router v1.0.0 with an
InferencePool. The `conv` window of the replayed Azure trace was thinned to
0.6 x C in runs 1 and 2, and to 1.5 x C in run 3. Each request goes to
**premium** (priority 10, never shed) with probability 0.3, or to **batch**
(priority -10, sheddable after 10 x T). The `nopolicy` arm runs the same
router with flow control off.

## Runs

| Run | Head | Config | Job 1 runner | Job 2 runner |
|---|---|---|---|---|
| run 1: [46052787808](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46052787808) job 1, [46052881592](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46052881592) job 2 | `ba9ffd3` | protocol: default `utilization-detector`, batch ceiling 0.6, 0.6 x C | Intel Xeon 6975P-C | Intel Xeon 6975P-C |
| run 2: [46064579619](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46064579619) | `591965e` | amendment 1: `concurrency-detector`, 1 request per replica, batch ceiling 0.5, 0.6 x C | Intel Xeon 6975P-C | AMD EPYC 9V74 |
| run 3: [46075317035](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46075317035) | `f46de98` | amendment 2: as run 2, at 1.5 x C | Intel Xeon 6975P-C | AMD EPYC 9V74 |

Run 1's first job 2 was stopped by the runner check (Intel without AMX)
before any measurement, and was run again alone (46052881592).

## Calibration

| Run, job | T | P | C | Replay mean | Requests per rep (premium / batch) |
|---|---|---|---|---|---|
| run 1, job 1 | 0.7 s | 0.11 s | 0.5 req/s | 0.3 req/s | 130 / 245 |
| run 1, job 2 | 0.7 s | 0.12 s | 0.5 req/s | 0.3 req/s | 130 / 245 |
| run 2, job 1 | 0.7 s | 0.14 s | 0.5 req/s | 0.3 req/s | 130 / 245 |
| run 2, job 2 (AMD) | 4.2 s | 0.12 s | 0.25 req/s | 0.15 req/s | 67 / 127 |
| run 3, job 1 | 0.7 s | 0.13 s | 0.75 req/s | 1.125 req/s | 415 / 927 |
| run 3, job 2 (AMD) | 4.1 s | 0.13 s | 0.25 req/s | 0.375 req/s | 153 / 311 |

## Results

Budget is the error budget burned over the replay, against the tenant's
own budget (premium 1 %, batch 5 %). Queue p95 is the
`x-llm-d-flow-queue-duration-ms` response header, which only the flow
control path sends. EUR per million good tokens uses the step 7 reference
price (0.2134 USD/h at 0.86 EUR/USD).

| Run, job | Rep | Premium budget | Premium TTFT p95 | Premium queue p95 | Batch responses | Batch budget | Batch queue p95 | EUR per M good tokens |
|---|---|---|---|---|---|---|---|---|
| run 1, job 1 | nopolicy 1 / 2 | 1231 % / 1462 % | 0.81 / 0.53 s | n/a | 245 x 200 | 0 % | n/a | 8.77 / 8.78 |
| run 1, job 1 | guardrail 1 / 2 | 1077 % / 692 % | 0.37 / 0.27 s | 0 / 0 ms | 245 x 200 | 0 % | 0 / 0 ms | 8.75 / 8.65 |
| run 1, job 2 | nopolicy 1 / 2 | 308 % / 769 % | 0.30 / 0.48 s | n/a | 245 x 200 | 0 % | n/a | 8.55 / 8.59 |
| run 1, job 2 | guardrail 1 / 2 | 692 % / 385 % | 0.66 / 0.24 s | 0 / 0 ms | 245 x 200 | 8 % / 0 % | 0 / 0 ms | 8.62 / 8.55 |
| run 2, job 1 | nopolicy 1 / 2 | 538 % / 154 % | 0.73 / 0.26 s | n/a | 245 x 200 | 0 % | n/a | 8.57 / 8.52 |
| run 2, job 1 | guardrail 1 / 2 | 615 % / 308 % | 0.86 / 0.41 s | 315 / 1 ms | 245 x 200 | 0 % | 3328 / 2688 ms | 8.73 / 8.63 |
| run 2, job 2 | nopolicy 1 / 2 | 448 % / 299 % | 2.05 / 0.52 s | n/a | 127 x 200 | 0 % | n/a | 15.62 / 15.58 |
| run 2, job 2 | guardrail 1 / 2 | 0 % / 299 % | 2.30 / 0.41 s | 0 / 0 ms | 127 x 200 | 0 % | 2813 / 1989 ms | 15.45 / 15.53 |
| **run 3, job 1** | nopolicy 1 / 2 | 2458 % / 2386 % | 0.91 / 0.92 s | n/a | 927 x 200 | 15 % / 26 % | n/a | **2.45 / 2.43** |
| **run 3, job 1** | guardrail 1 / 2 | 3735 % / 3253 % | 4.73 / 4.63 s | 4306 / 4462 ms | 545 x 200, **382 x 429** / 587 x 200, **340 x 429** | 1064 % / 962 % | 7336 / 7359 ms | **4.31 / 4.05** |
| run 3, job 2 | nopolicy 1 / 2 | 719 % / 261 % | 2.32 / 0.73 s | n/a | 311 x 200 | 19 % / 0 % | n/a | 6.91 / 6.80 |
| run 3, job 2 | guardrail 1 / 2 | 327 % / 0 % | 2.55 / 1.65 s | 1039 / 665 ms | 311 x 200 | 0 % | 7558 / 4612 ms | 6.81 / 6.77 |

Every response in runs 1 and 2 was a 200 with a first chunk. In run 3 the
only other response was 429, on batch, in job 1. No request timed out or
failed in any run.

## Hypotheses

| # | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| H1 premium protected (guardrail <= half of nopolicy, and <= 100 % in every guardrail rep) | **refuted**: 885 % vs 1346 % (job 1), 538 % vs 538 % (job 2) | **refuted**: 462 % vs 346 % (job 1), 149 % vs 373 % (job 2); worst guardrail rep 615 % | **refuted**: 3494 % vs 2422 % (job 1, worse with the guardrail); 163 % vs 490 % (job 2, better, but the worst guardrail rep was 327 %) |
| H2 no waste (EUR per M good tokens <= 1.1 x) | holds: 8.70 vs 8.78, 8.58 vs 8.57 | holds: 8.68 vs 8.54, 15.49 vs 15.60 | **refuted** in job 1: 4.18 vs 2.44 (1.71 x); holds in job 2: 6.79 vs 6.85 |
| H3 declared (0 premium non-200; batch non-200 only 429) | holds, every rep | holds, every rep | holds, every rep: 722 batch requests shed, all with 429; no 5xx, no timeout |

## What the numbers say

1. **With the chart's defaults the guardrail never acts on this pool.**
   In run 1 no batch request was held or shed, and the queue header read
   0 ms. The default `utilization-detector` scores a pod as
   max(waiting queue / 5, KV cache use / 0.8). vLLM's default
   `--max-num-seqs` runs every request at once, so its waiting queue stays
   at 0, and 1 GiB of KV cache per replica is nearly empty at these lengths.
   The router saw an idle pool while two requests sharing one 2-core
   replica burned the premium budget 3 to 15 times over. On a real pool the
   lesson is the same: **declare capacity**, or the default signal arrives
   only when the engine's own queue is full.
2. **Declaring capacity in requests turns the guardrail on.** With the
   upstream `concurrency-detector` at 1 request per replica (amendment 1),
   batch waited in the EPP (queue p95 2.0 to 3.3 s, inside its 10 x T
   budget) and premium went first. It was configuration only, versioned
   in Git, and it can be rolled back with one values file.
3. **At 0.6 x C it does not show a gain, because there is nothing to
   protect against.** The premium budget is 1 % of 130 requests, 1.3
   requests per rep. Two reps of the same arm in the same job differed by
   up to 3.5 times (538 % and 154 %), more than any difference between the
   arms. The misses are a handful of requests (0 to 19 per rep), present
   with and without the policy. The cost was the same in every arm (H2),
   and nothing was ever answered with anything but 200 (H3).
4. **Above capacity, a cap set at the one-at-a-time SLO point costs more
   than it saves.** Run 3, job 1, at 1.125 req/s: with no policy, vLLM's
   continuous batching served every request, premium TTFT p95 0.91 s, at
   2.44 EUR per million good tokens. With the guardrail the pool ran at
   most 2 requests at a time, so premium waited 4.3 to 4.5 s in the EPP
   (p95), its budget got worse (3494 % against 2422 %), 37 to 41 % of batch
   was shed with 429, and each good token cost 1.71 times as much. The
   policy did what it was configured to do. The declared capacity, 1
   request per replica, was below what the engine can batch at the same
   SLO. On the slower AMD runner (job 2, 0.375 req/s) the same policy
   halved the premium budget at the median (163 % against 490 %) at the
   same cost, but not in every rep.
5. **What this means for a platform.** Admission control on a fixed pool
   is only as good as its declared capacity. The default reads a queue
   that a continuous-batching engine does not fill. A cap at the
   single-request SLO point throws away batching throughput. The capacity
   to declare is the engine's throughput knee at the SLO, measured per
   model and per hardware, and it has to be measured again when either
   changes. That measurement is not done here. Shedding itself worked as
   designed: every degraded request got a 429 the client can act on.

## What this does not show

The protocol's list: no GPU pool, no real tenants, no gateway in front, no
cost-driven controller, one tenant per priority, a 30/70 mix chosen rather
than measured. Two reps per arm and job give a direction, not an interval.
