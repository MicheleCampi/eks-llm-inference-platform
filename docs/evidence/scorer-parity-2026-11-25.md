# Experiment evidence: legacy scorers against endpoint-attribute-scorer, on kind (2026-11-25)

Protocol and hypotheses: [`experiments/prefix-routing/PARITY.md`](../../experiments/prefix-routing/PARITY.md),
written before the run. Workflow: `.github/workflows/scorer-parity.yml`.
Context: llm-d-router issue #2059 (benchmark the generic scorer before the
legacy ones are deprecated). Cost: 0 (GitHub-hosted runners, no AWS resources).

One run: [45586397311](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45586397311),
commit 360bb6e. kind v0.33.0, Kubernetes v1.36.4. EPP built in the job from
llm-d-router main at `32a075e2`, chart `llm-d-router-standalone` from the
same checkout, Envoy distroless-v1.40.2 by digest. Both arms run with
`allow-experimental-plugins: "true"`; they differ only in the scorers:

- **legacy**: queue-scorer 2, kv-cache-utilization-scorer 2, prefix-cache-scorer 3, no-hit-lru-scorer 2 (upstream `optimized-baseline.yaml`);
- **ea**: the two legacy scorers replaced by endpoint-attribute-scorer on `WaitingQueueSize` (adaptive range) and `KVCacheUsagePercent` (fixed range 0 to 1), same weights (upstream `endpoint-attribute-parity.yaml`).

Four repetitions per arm, order alternated (legacy, ea / ea, legacy / ...),
prefix caches emptied and a fresh EPP before every arm.

## vLLM CPU v0.34.0, 2 replicas, Qwen2.5-0.5B-Instruct

Same set-up as the prefix-routing experiment: 2 cores per replica, 4352
tokens of prefix cache per replica, 8 groups of 768 words, 160 requests per
arm at concurrency 4, 8 output tokens. Hit rate from the servers' own
counters; TTFT client-side, streaming.

| arm | requests ok/total | hit rate per rep (1-4) | median hit rate | TTFT p50 per rep (s) | median TTFT p50 | requests per replica |
|---|---|---|---|---|---|---|
| legacy | 640/640 | 0.721, 0.720, 0.735, 0.768 | 0.728 | 0.391, 0.379, 0.448, 0.350 | 0.385 s | 82,78 / 88,72 / 79,81 / 77,83 |
| ea | 639/640 | 0.741, 0.734, 0.756, 0.746 | 0.744 | 0.382, 0.453, 0.354, 0.419 | 0.401 s | 84,76 / 80,79 / 84,76 / 75,85 |

## llm-d-inference-sim v1.2.0, 4 replicas

16 groups, 800 requests per arm at concurrency 16. On the simulator the
TTFT follows from the hit rate, so only the hit rate and the spread are
results.

| arm | requests ok/total | hit rate per rep (1-4) | median hit rate | requests per replica |
|---|---|---|---|---|
| legacy | 3200/3200 | 0.743, 0.685, 0.697, 0.676 | 0.691 | 188,198,218,196 / 189,199,199,213 / 216,199,205,180 / 203,202,187,208 |
| ea | 3200/3200 | 0.715, 0.671, 0.706, 0.716 | 0.711 | 194,198,196,212 / 193,186,196,225 / 204,200,201,195 / 208,209,189,194 |

## Hypotheses

| # | Hypothesis | Result |
|---|---|---|
| P1 | median hit rate of ea within 0.03 of legacy | **met** on both backends: vLLM +0.016 (0.744 vs 0.728), sim +0.020 (0.711 vs 0.691). The per-repetition ranges overlap on both. |
| P2 | median TTFT p50 of ea within 10 % of legacy, vLLM | **met**: +4.0 % (0.401 s vs 0.385 s). The per-repetition ranges overlap (legacy 0.350 to 0.448 s, ea 0.354 to 0.453 s). |
| P3 | no failures; no replica above 2x another | **spread met** (largest ratio 88/72 = 1.22 on vLLM, 225/186 = 1.21 on sim). **Failures not met: 1 of 640 vLLM requests failed in the ea arm**, repetition 2: Envoy's 503 "upstream connect error or disconnect/reset before headers. reset reason: connection termination". No failure in the 640 legacy vLLM requests or in the 6400 simulator requests. |

## Reading

- With the same EPP build, chart, load and pods, the endpoint-attribute
  configuration routed like the legacy one: same hit rate within the noise
  between repetitions, same TTFT within 4 %, same balance across replicas.
- The one failure is an Envoy-to-vLLM connection reset before response
  headers. The same error, once in 2880 requests, appeared in the
  prefix-routing run of 2026-11-23 on llm-d-router v1.0.0 with the legacy
  scorers (`prefix-routing-2026-11-23.md`, H4). The scorer chooses a pod; it
  does not hold the connection. This points to the proxy or the server, not
  to the scorer, but this run does not prove it: the EPP and Envoy logs are
  in the run's artifact and were not read here.

## Limits

- CPU, small model, short output, 2 vLLM replicas: this shows the two
  configurations make the same routing choices under real metrics. It says
  nothing about GPU-scale load, and nothing about EPP CPU or scheduler
  latency, which the upstream nightly target measures.
- One run of four repetitions per arm on one runner.
