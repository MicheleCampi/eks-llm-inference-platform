# Prefix-aware routing against kube-proxy, on kind

Written 2026-11-23, before any run. Results go to
`docs/evidence/prefix-routing-<date>.md`; this file is not edited to fit them.

## Question

With many tenants (agents, chat sessions) that each repeat a long system
prompt, does a router that sends a request to the replica already holding
its prefix in the KV cache (llm-d-router, the endpoint picker of the Gateway
API Inference Extension) give a higher prefix-cache hit rate and a lower time
to first token than a plain Kubernetes Service, on the same pods and the same
load? And what does it cost?

## Set-up

All pinned in `versions.env`. One kind node (Kubernetes v1.36.4) on a
GitHub-hosted runner (4 CPUs, 16 GiB), zero cloud cost.

| | |
|---|---|
| Router | llm-d-router **v1.0.0** (latest release, 2026-10-16), chart `llm-d-router-standalone`: EPP plus an Envoy sidecar, selecting pods by label. No Gateway, no InferencePool: standalone mode needs neither. |
| Backend `sim` | llm-d-inference-sim v1.2.0, **4 replicas**, simulated prefix cache of 4352 tokens each (272 blocks of 16). |
| Backend `vllm` | vLLM CPU **v0.34.0**, Qwen2.5-0.5B-Instruct at a pinned commit, **2 replicas** on 2 dedicated cores each, prefix caching on, cache cut to the same 4352 tokens (136 blocks of 32, `--num-gpu-blocks-override`). |
| Load | `loadgen.py`, in a pod (a port-forward would pin all requests to one pod). |

The cache is cut on purpose. With the default 1 GiB of KV cache one vLLM
replica holds about 100 prompts of 800 tokens, and filling it on CPU would
take hours; a cache of 4352 tokens shows the same effect with 8 prompts.

## Arms

Same pods, same request sequence (seeded), caches emptied before each arm.

1. **service**: the ClusterIP Service. kube-proxy (iptables) picks a pod at
   random per connection; the load generator opens one per request.
2. **random**: EPP and Envoy with the `random-picker` only. Isolates the cost
   of the extra hop: it routes like the Service but through the router.
3. **prefix**: EPP and Envoy with the chart's **default** configuration at
   v1.0.0 (queue-scorer 2, kv-cache-utilization-scorer 2, prefix-cache-scorer
   3, approximate prefix index, no tokenizer sidecar). What a team gets out of
   the box, nothing tuned.

Each arm runs 3 times, the order reversed on each repetition.

## Workload

G groups, each a fixed system prompt of 768 words, and requests that pick a
group at random and add a unique 32-word question; 8 output tokens (a short
answer keeps CPU time on the prefill, where the cache acts). Streaming, so
TTFT is measured at the first chunk.

G is set from the capacity the servers report, by a rule fixed here: the
working set is **0.75 x capacity x replicas**. It fits across the replicas
only if each replica keeps its own share of the groups; any replica that
sees every group must evict. With 4352 tokens: G = 8 for 2 vLLM replicas,
16 for 4 simulated ones.

| | sim | vllm |
|---|---|---|
| requests per arm | 800 | 160 |
| concurrency | 16 | 4 |

## Measures

- **Prefix-cache hit rate**: the model servers' own counters
  (`vllm:prefix_cache_hits` / `vllm:prefix_cache_queries`, tokens), read
  from every replica before and after the arm. Not the router's prediction.
- **TTFT** p50, p90, mean, client-side. On `sim` the TTFT is derived from the
  hit rate by the simulator (uncached tokens x 200 us), so it is not a result;
  only `vllm` TTFT is.
- Requests per replica (`vllm:request_success`), failures.

## Hypotheses

| # | Hypothesis | Arms |
|---|---|---|
| H1 | prefix hit rate at least 2x the service hit rate, on both backends | prefix vs service |
| H2 | on vLLM, prefix TTFT p50 at least 30 % lower than service | prefix vs service, vllm |
| H3 | the router hop costs little: random TTFT p50 within 10 % of service, hit rates within 0.05 | random vs service |
| H4 | no request fails; under prefix routing no replica gets more than 2x the requests of another | all |

If H1 fails, the router's default is not affinity enough for this load, and
the next step is its configuration (weights, `no-hit-lru-scorer`, precise
prefix with KV events), not a claim.

## Limits, declared before the run

- CPU, small model, short output: the TTFT gain is a prefill gain on CPU.
  On a GPU, prefill is far faster, so the absolute gain is smaller per token
  and larger only with longer prompts. No GPU number follows from this.
- One node: no network between replicas, no node failure.
- kube-proxy is random, not round-robin; that is what a Service does.
- Router at v1.0.0. The endpoint-attribute scorers of llm-d-router #2059
  are on `main` only; they are a later arm, not this one.

## Run it

```bash
bash experiments/prefix-routing/run.sh up
bash experiments/prefix-routing/run.sh backend sim     # or vllm (see the workflow)
bash experiments/prefix-routing/run.sh arm service 1
bash experiments/prefix-routing/run.sh arm random 1
bash experiments/prefix-routing/run.sh arm prefix 1
bash experiments/prefix-routing/run.sh report
bash experiments/prefix-routing/run.sh down
```

In CI: `.github/workflows/prefix-routing.yml` (on pull requests that touch
the experiment, and on demand).
