# The keep-alive race against real vLLM on kind

Written 2026-11-26, before the run, after the stand-in runs of README.md.
Results go to `docs/evidence/keepalive-race-<date>.md`; this file is not
edited to fit them. Workflow: `.github/workflows/keepalive-race.yml`, job
`kind`, one job per arm. Cost: 0 (GitHub-hosted runners).

## Set-up

| Part | What |
|---|---|
| Cluster | kind, the prefix-routing cluster (`../prefix-routing/run.sh up`) |
| Model server | vLLM CPU v0.34.0 by digest, Qwen2.5-0.5B-Instruct at the pinned revision, `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=5` (the vLLM default), scaled to **one** replica |
| Router | llm-d-router-standalone chart from llm-d-router main at 32a075e2, EPP from llm-d's per-commit build by digest, Envoy `distroless-v1.40.2`, `legacy` scorer values: the set-up of live A-025's `legacy` arm |
| Arm | `envoy_patch.py` on the rendered ConfigMap, then a rollout restart. `chart`: unchanged. `idle`: upstream `idle_timeout: 4s` on `original_destination_cluster`. `retry`: `retry_on: reset`, 1 retry, on the routes to it. All arms add the attempt count to the JSON access log |
| Client | `client.py` in a pod, one connection to `router-epp:8081`, one short prompt, `max_tokens: 1`, gap uniform in **4.90 to 5.00 s**, 241 requests (the first opens the connection and is not counted) |

One replica means the EPP always picks the same pod, so the one Envoy
worker that serves the client's connection reuses one pooled connection.
The idle time of that connection is the gap plus the EPP's processing time
(a few ms to tens of ms on kind), which is why the window is 100 ms wide
rather than the 6 ms of the stand-in runs.

## Hypotheses

| # | Hypothesis |
|---|---|
| K3 | `chart`: at least 2 failures in 240, each a 503 with flag `UC` and `connection_termination` in the Envoy access log, upstream = the vLLM pod |
| K4 | `idle`: 0 failures in 240 |
| K5 | `retry`: 0 failures seen by the client in 240 |

If K3 holds, the race is shown against vLLM itself, behind the chart the
failures of eks #89/#93/#94 and A-025 came from. If K3 holds and K4 holds,
the upstream idle timeout below vLLM's keep-alive is the remedy to propose
(eks first, then upstream to llm-d-router, issue with a PR to follow). If K3
fails, the stand-in result stays a mechanism that fits, not a proof for
vLLM, and this file says so in the evidence.

## Limits

- One replica and one client connection: this tests the mechanism under
  control, not the rate under the prefix-routing load. The rate under load
  depends on how often a (worker, pod) connection sits idle for about 5 s.
- 240 requests per arm cannot show a rate of 1 in 1000 is zero; K4 and K5
  are read against K3 in the same window.
