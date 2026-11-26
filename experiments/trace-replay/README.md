# SLO under production-shaped traffic: replaying a public Azure LLM trace, on kind

Written 2026-11-26, before any code or run. Results go to
`docs/evidence/trace-replay-<date>.md`; this file is not edited to fit them.
Any change after the first run is a dated amendment at the end.

## Question

Synthetic load (constant concurrency, random arrivals) hides the thing that
breaks a serving SLO in production: bursts. Under the arrival pattern and
token lengths of a real LLM service, scaled to our CPU capacity:

1. How much of the error budget does a two-replica vLLM deployment burn, and
   where (peak minutes or everywhere)?
2. Does the load-aware router (llm-d-router v1.0.0, default plugins) keep
   more requests inside the SLO than a plain Kubernetes Service, on the same
   pods and the same replayed sequence?
3. What does a million tokens cost, and a million tokens **inside the SLO**
   (goodput cost)?

## Traffic source

Azure LLM inference trace 2023 (Azure/AzurePublicDataset,
`AzureLLMInferenceTrace_conv.csv` and `AzureLLMInferenceTrace_code.csv`),
licensed CC-BY 4.0. Attribution, as the dataset asks: Patel et al.,
"Splitwise: Efficient generative LLM inference using phase splitting",
ISCA 2024. The CSVs are not committed: `run.sh` downloads them and checks
the SHA-256 below (read 2026-11-26); a mismatch stops the run.

| File | SHA-256 | Rows | Span | Mean rate | Busiest / quietest minute | Context p50/p90/p99 | Generated p50/p90/p99 |
|---|---|---|---|---|---|---|---|
| conv | `2f1e5b66…dcc7d0bf8` | 19,366 | 58 min | 5.53 req/s | 502 / 7 req | 1020 / 2734 / 4142 | 129 / 424 / 601 |
| code | `54e9a6d2…f2277fb6` | 8,819 | 57 min | 2.57 req/s | 585 / 1 req | 1469 / 5186 / 7436 | 13 / 55 / 249 |

Full digests: conv `2f1e5b666d4e3055fdbba98598ce2ec307767b9064e03e2fa46676dbcc7d0bf8`,
code `54e9a6d2a4bd06ba1e060304b900abbc74cbea53de96506e60fe5bb4f2277fb6`.

The trace gives arrival times and token counts only, not prompt text. Prompts
are generated with the requested length from a fixed word list and a seed,
each one unique, so prefix caching plays no part: the router is tested on
load balancing under bursts, not on prefix affinity (that is
`experiments/prefix-routing`).

## Scaling rules (fixed here)

Our capacity is two vLLM CPU replicas, not an Azure GPU fleet, so the trace is
scaled in two ways, each with one fixed rule:

- **Lengths:** context and generated tokens divided by 8, minimum 1 (conv p50
  becomes 128 / 16). The shape of the distributions is kept; absolute
  lengths are not.
- **Rate:** a calibration run measures capacity C, the highest Poisson rate
  (req/s, both replicas) of the ladder 0.25, 0.5, 1, 2, 4, 8, 16, 60 s per
  step, at which TTFT p95 stays at or under T, TPOT p95 at or under P and no
  request fails, refined by one step at the midpoint between the last pass
  and the first fail. Arrivals are then thinned by uniform random
  sampling (seeded) so that the mean offered rate over the replay window is
  **0.6 x C**. Thinning keeps the burst shape: a minute at 5x the mean stays
  at 5x the mean.
- **Window:** 20 minutes of each trace, the ones that contain its busiest
  minute (chosen by script, printed in the report), replayed in real time.

## Set-up

As `experiments/prefix-routing` (pinned in its `versions.env`): one kind node
on a GitHub-hosted runner, vLLM CPU v0.34.0, Qwen2.5-0.5B-Instruct at the
pinned commit, 2 replicas on 2 dedicated cores each, llm-d-router v1.0.0
standalone with Envoy upstream idle timeout 4 s (D-0170). The runner's CPU
model is printed in the report; runners that cannot start vLLM CPU stop the
run early, as in the keep-alive experiment.

## Arms

Same pods, same replayed sequence, caches emptied before each arm.

1. **service**: the ClusterIP Service (kube-proxy, random per connection).
2. **router**: llm-d-router v1.0.0 with the chart's default configuration.

Each arm runs twice per trace (conv, code), order reversed the second time.

## SLO and error budget (fixed here)

- **SLI:** a request is good if it completes without error, TTFT is at or
  below T, and mean time per output token is at or below P.
- **T and P** come from a calibration run with no queueing: one request at
  a time (40 requests, lengths drawn from the window) through the Service.
  T = 2 x its TTFT p95, P = 2 x its TPOT p95, rounded up to 0.1 s and
  0.01 s, written in the report before the arms run (amendment 1).
- **Objective:** 99 % of requests good over the window. Error budget = 1 %
  of requests. Budget burned = bad fraction / 1 %; above 100 % the SLO is
  broken.
- Burn is reported per minute too, to show whether it is spent in the peak
  minutes or everywhere.

## Cost (fixed here)

The kind runner has no price, so cost uses a **reference price**, stated as
such: m7i-flex.large on-demand in eu-west-1, 0.1067 USD/h for 2 vCPU (the
price in `registro/BUDGET.md`, read 17/11), so 4 vCPU of replicas =
0.2134 USD/h; converted to EUR at the rate printed in the report.

- EUR per million generated tokens = reference price x window hours /
  generated tokens.
- **EUR per million good tokens** = the same price / tokens of good requests
  only. It is the cost of the output that met the SLO.

## Hypotheses

| # | Hypothesis | Arms |
|---|---|---|
| H1 | at 0.6 x C mean load the service arm breaks the SLO (budget burned > 100 %) on at least one trace, and more than half of the bad requests fall in the busiest 20 % of minutes | service |
| H2 | the router arm burns at least 25 % less error budget than the service arm on both traces | router vs service |
| H3 | EUR per million generated tokens differs by less than 5 % between arms (same pods); EUR per million good tokens is lower on the router arm | both |

A refuted hypothesis is published as refuted.

## What this does not show

- Real users: the traffic shape is real, the users are not.
- GPU numbers: CPU only, small model, lengths scaled by 8.
- Prefix effects: prompts are unique by construction.
- Autoscaling: replicas are fixed; scaling under the trace is a later step
  (ROADMAP step 9, FinOps guardrail at the peak).

## Next (not part of this protocol)

The same replay is the load for the canary-with-rollback experiment (ROADMAP
step 8) and for the closed-loop cost guardrail (step 9).

## Amendments

1. **2026-11-26, before any run, while writing the code.** (a) T and P came
   from "the calibration run at 0.2 x C", but C is defined with T: circular.
   T and P now come from a closed-loop run, one request at a time, which has
   no queueing by construction. (b) If 0.6 x C is above the window's mean
   rate nothing can be thinned; time is then compressed by that ratio
   instead, which keeps every arrival and the burst shape and shortens the
   replay (`trace.py thin`, reported as `time_speedup`). (c) A scaled
   request longer than the backend's context window (2048 tokens, less a
   margin of 48) has its context clipped; the count is reported (0 in both
   20-minute windows on 2026-11-26). (d) Generated length is exact
   (`ignore_eos`, `min_tokens`); prompts are built from words and the
   server's own prompt token count is recorded next to the requested length.
