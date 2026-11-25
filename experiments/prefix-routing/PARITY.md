# Scorer parity: legacy scorers against endpoint-attribute-scorer, on kind

Written 2026-11-25, before any run. Results go to
`docs/evidence/scorer-parity-<date>.md`; this file is not edited to fit them.

## Question

llm-d-router #2059 asks for a benchmark of the generic
`endpoint-attribute-scorer` against the legacy `queue-scorer` and
`kv-cache-utilization-scorer` before the legacy ones are deprecated. The
maintainer (liu-cong, 2026-11-24) accepts a run on the simulator and prefers
real model servers. With the same pods, load, EPP build and chart, does the
endpoint-attribute configuration route like the legacy one?

The upstream nightly target (`endpoint-attribute-parity-job1`) measures EPP
CPU, memory and scheduler latency on simulated servers. This run measures
the routing outcome on real vLLM servers: prefix-cache hit rate, TTFT and
requests per replica. The two are complementary.

## Set-up

Everything as in `README.md` (same kind node, backends, load generator,
workload rule and cache cut), except the router:

| | |
|---|---|
| EPP | built in CI from llm-d-router main at `ROUTER_MAIN_COMMIT` (`Dockerfile.epp`), loaded into kind, never pulled. |
| Chart | `config/charts/llm-d-router-standalone` from the same checkout; Envoy `distroless-v1.40.2` as that chart ships it, pinned by digest. |
| Flags | `allow-experimental-plugins: "true"` in both arms (endpoint-attribute-scorer is Alpha). |

## Arms

1. **legacy**: `values/legacy.yaml`, the plugin set of upstream
   `test/perf/config/router-configs/optimized-baseline.yaml`: queue-scorer 2,
   kv-cache-utilization-scorer 2, prefix-cache-scorer 3, no-hit-lru-scorer 2.
2. **ea**: `values/ea.yaml`, the plugin set of upstream
   `endpoint-attribute-parity.yaml`: the two legacy scorers replaced by
   endpoint-attribute-scorer on `WaitingQueueSize` (adaptive range) and
   `KVCacheUsagePercent` (fixed range 0 to 1), same weights.

Four repetitions per arm, order alternated (legacy, ea / ea, legacy / ...),
caches emptied and a fresh EPP before every arm.

## Hypotheses

| # | Hypothesis | Backend |
|---|---|---|
| P1 | median prefix hit rate of ea within 0.03 of legacy | sim and vllm |
| P2 | median TTFT p50 of ea within 10 % of legacy | vllm |
| P3 | no request fails in either arm; under both arms no replica gets more than 2x the requests of another | both |

If P1 or P2 fails, the result is reported as a difference to investigate
(decision logs in `results/*.epp.log`), not as parity.

## Limits, declared before the run

- CPU, small model, short output, 2 vLLM replicas: this shows whether the
  two configurations make the same routing choices under real metrics. It
  says nothing about GPU-scale load.
- The arms differ only in configuration; any difference between them is
  within one EPP build, not between releases.
- Repetitions on one runner; runner drift is handled by alternating order,
  not removed.

## Run it

```bash
git clone https://github.com/llm-d/llm-d-router /tmp/llm-d-router
git -C /tmp/llm-d-router checkout "$ROUTER_MAIN_COMMIT"
docker build -f /tmp/llm-d-router/Dockerfile.epp -t "$ROUTER_MAIN_EPP_IMAGE" /tmp/llm-d-router
helm dependency update /tmp/llm-d-router/config/charts/llm-d-router-standalone
bash experiments/prefix-routing/run.sh up
kind load docker-image "$ROUTER_MAIN_EPP_IMAGE" --name prefix-routing
bash experiments/prefix-routing/run.sh backend sim     # or vllm (see the workflow)
ROUTER_SRC=/tmp/llm-d-router bash experiments/prefix-routing/run.sh arm legacy 1
ROUTER_SRC=/tmp/llm-d-router bash experiments/prefix-routing/run.sh arm ea 1
bash experiments/prefix-routing/run.sh report
```

In CI: `.github/workflows/scorer-parity.yml` (on pull requests that touch
this file, the two values files or the workflow, and on demand).
