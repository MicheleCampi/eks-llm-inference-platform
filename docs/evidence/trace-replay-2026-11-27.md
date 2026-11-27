# Experiment evidence: SLO under a replayed Azure LLM trace, on kind (2026-11-27)

Protocol and hypotheses: [`experiments/trace-replay/README.md`](../../experiments/trace-replay/README.md),
written before any run (amendment 1 before the first run, amendment 2 after
it, set-up only). Workflow: `.github/workflows/trace-replay.yml`.
Cost: 0 (GitHub-hosted runners, no AWS resources). EUR figures below use the
protocol's **reference price** (0.2134 USD/h for 4 vCPU of replicas,
0.86 EUR per USD assumed), not a price paid.

Traffic: the 20 minutes around the busiest minute of the Azure LLM inference
traces 2023 (`conv` and `code`, AzurePublicDataset, CC-BY 4.0, Patel et al.,
Splitwise, ISCA 2024), files pinned by SHA-256, lengths divided by 8, replayed
open loop at 0.6 x the capacity C measured on the same runner. The burst shape
is the real one; the users are not.

Set-up: kind, vLLM CPU **v0.34.0**, Qwen2.5-0.5B-Instruct, 2 replicas on 2
cores each, llm-d-router **v1.0.0** with the chart's default plugins and Envoy
upstream idle timeout 4 s (D-0170). Prompts are unique by construction, so
prefix caching plays no part.

## Runs

| Run | Set-up | Runner CPU | Valid for |
|---|---|---|---|
| [45905549505](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45905549505) | before amendment 2 | AMD EPYC 9V74, 4 CPUs | conv complete; code repetition 1 only (rep 2 stopped, exit 137 during the cache reset) |
| [45915164527](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45915164527) | amendment 2 (`e06c0d5`) | Intel Xeon 6975P-C, 4 CPUs | **both traces complete**: the evidence |

In run 45915164527 the first `conv` job landed on an AMD EPYC 7763 without
AVX-512 and stopped at the runner check, before any measurement; only that job
was re-run, once (attempt 2). `code` is from attempt 1.

## Calibration (run 45915164527)

| Trace | T (2 x TTFT p95, one at a time) | P (2 x TPOT p95) | C (highest Poisson rate within SLO) | Replay mean |
|---|---|---|---|---|
| conv | 0.7 s | 0.11 s | 0.375 req/s | 0.225 req/s |
| code | 0.9 s | 0.20 s | 0.5 req/s | 0.3 req/s |

## Results (run 45915164527)

Objective 99 % good over the window; budget burned above 100 % = SLO broken.
No request failed in any arm; every bad request is a slow one.

| Trace | Arm | Rep | Requests | Good | Budget burned | Bad in busiest 20 % of minutes | TTFT p50 / p95 | TPOT p95 | EUR / M tokens | EUR / M good tokens |
|---|---|---|---|---|---|---|---|---|---|---|
| conv | service | 1 | 290 | 0.9655 | 345 % | 0.50 | 0.114 / 0.448 s | 0.100 s | 10.85 | 11.12 |
| conv | service | 2 | 290 | 0.9724 | 276 % | 0.25 | 0.106 / 0.326 s | 0.094 s | 10.85 | 10.98 |
| conv | router | 1 | 290 | 0.9069 | 931 % | 0.22 | 0.126 / 0.437 s | 0.122 s | 10.85 | 11.63 |
| conv | router | 2 | 290 | 0.9103 | 897 % | 0.35 | 0.126 / 0.577 s | 0.119 s | 10.85 | 11.65 |
| code | service | 1 | 351 | 0.9174 | 826 % | 0.52 | 0.190 / 0.993 s | 0.210 s | 58.04 | 61.73 |
| code | service | 2 | 351 | 0.9202 | 798 % | 0.54 | 0.177 / 0.919 s | 0.273 s | 58.04 | 61.42 |
| code | router | 1 | 351 | 0.9060 | 940 % | 0.52 | 0.230 / 1.033 s | 0.228 s | 58.04 | 61.98 |
| code | router | 2 | 351 | 0.8661 | 1339 % | 0.43 | 0.216 / 1.322 s | 0.314 s | 58.04 | 63.72 |

Dispatch lag p99 of the replayer at most 0.012 s in every arm: the schedule
was kept.

## Hypotheses (medians of the 2 repetitions, as written before the run)

| # | Verdict | Numbers |
|---|---|---|
| H1: service breaks the SLO on at least one trace, more than half of the bad requests in the busiest 20 % of minutes | **holds** (on code) | code: 812 % burned, 0.53 of bad requests in the peak minutes; conv: 310 % burned, but 0.38 in the peak minutes |
| H2: router burns at least 25 % less budget than service on both traces | **refuted** | conv 310 % service vs 914 % router; code 812 % vs 1140 %. The router burned **more**, on both traces |
| H3: EUR / M tokens within 5 % between arms, EUR / M good tokens lower on router | **refuted** (second half) | EUR / M tokens equal (10.85, 58.04: same pods, same tokens); EUR / M good tokens higher on router: conv 11.05 vs 11.64 (+5 %), code 61.58 vs 62.85 (+2 %) |

## The earlier run, for comparison (run 45905549505, AMD EPYC 9V74)

Same rules; the calibration on this CPU gave a much looser SLO (T 4.2 s conv,
4.7 s code) and a lower capacity (C 0.25 req/s on both).

| Trace | Arm | Rep | Requests | Budget burned | TTFT p95 | TPOT p95 | EUR / M good tokens |
|---|---|---|---|---|---|---|---|
| conv | service | 1, 2 | 194 | 258 %, 258 % | 2.121, 2.073 s | 0.115, 0.106 s | 15.68, 15.67 |
| conv | router | 1, 2 | 194 | 619 %, 567 % | 2.208, 2.250 s | 0.137, 0.135 s | 16.01, 15.98 |
| code | service | 1 | 187 | 1551 % | 5.333 s | 1.949 s | 151.80 |
| code | router | 1 | 187 | 1176 % | 5.650 s | 2.012 s | 144.62 |

On conv the earlier run agrees: the router burns about 2.3 x the budget of
the Service. On code its single repetition went the other way (router -24 %),
which is inside the spread the later run shows between repetitions of the
same arm (940 % to 1339 %).

## What it shows

1. **A real burst breaks an SLO calibrated at quiet load, at 60 % of measured
   capacity.** Every arm burned its error budget several times over; on the
   code trace half of the bad requests sit in the busiest fifth of the
   minutes. Average utilisation is the wrong sizing input; the peak minutes
   are where the budget goes (H1).
2. **Without shared prefixes the router does not pay for itself.** With
   unique prompts the prefix scorer has nothing to find; what is left is an
   extra hop (Envoy and the endpoint picker) and load-aware scoring on two
   replicas. TTFT p50 is 12 to 40 ms higher on the router in every pair, and
   with T = 0.7 s a few tens of milliseconds are enough to push requests that were close to the line over it. On 2026-11-23 the
   same router on the same pods gave -39 % to -61 % TTFT p50 with shared
   prefixes ([prefix-routing-2026-11-23.md](prefix-routing-2026-11-23.md)).
   The two results together are the rule: route by prefix when the traffic
   has prefixes, and measure the hop when it does not.
3. **Cost per good token is the number that moves; cost per token does not.**
   Same pods, same tokens, so EUR / M tokens is identical by construction; the
   SLO misses show up only in EUR / M good tokens (+2 % to +5 % on the
   router).
4. **The runner's CPU changes the SLO itself.** The same calibration gave
   T = 4.2 s on an AMD EPYC 9V74 and 0.7 s on an Intel Xeon 6975P-C (AMX):
   a 6 x gap. That is why T and P are measured per run, not fixed in advance,
   and why results from different CPUs are not pooled.

## Limits

- Two repetitions per arm and one valid run per trace on the evidence CPU;
  the spread between repetitions (code router 940 % vs 1339 %) is as large as
  some differences between arms. H2 is refuted on the medians, and the earlier run points the
  same way in 2 of its 3 pairs; it is not a significance test.
- The cause in point 2 (extra hop, scoring with no prefix signal) is the
  reading that fits the TTFT p50 gap; the replayer does not record which pod
  served each request, so load balance between the two replicas is not
  measured here.
- CPU, small model, lengths scaled by 8, 2 fixed replicas: no GPU numbers,
  no autoscaling. The reference price is not a price paid.

## Next

The same replay is the load for the canary with SLO-based rollback (ROADMAP
step 8) and the FinOps guardrail at the peak (step 9). A per-pod field in the
replayer (the `x-gateway-destination-endpoint` header, or the pod's own
metrics) would settle the cause in point 2.
