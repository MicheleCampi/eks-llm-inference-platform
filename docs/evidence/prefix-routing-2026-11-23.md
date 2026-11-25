# Experiment evidence: prefix-aware routing against kube-proxy, on kind (2026-11-23)

Protocol and hypotheses: [`experiments/prefix-routing/README.md`](../../experiments/prefix-routing/README.md),
written before any run. Workflow: `.github/workflows/prefix-routing.yml`.
Cost: 0 (GitHub-hosted runners, no AWS resources).

Two complete, independent runs of the same commit range, on GitHub-hosted
runners with an **Intel Xeon 6975P-C, 4 CPUs, 15.3 GiB**:

- run [45287556802](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45287556802) (vLLM valid; its simulator job is invalid, see below);
- run [45290650216](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45290650216) (vLLM and simulator valid).

Each run: kind v0.33.0, Kubernetes v1.36.4, llm-d-router **v1.0.0** (chart
`llm-d-router-standalone`, EPP and Envoy by digest), every arm 3 times, the
order reversed each repetition, prefix caches emptied and a fresh EPP before
each arm.

## vLLM CPU v0.34.0, 2 replicas, Qwen2.5-0.5B-Instruct

2 cores per replica (no shared core), prefix caching on, 4352 tokens of
cache per replica (136 blocks of 32). 8 groups (shared system prompts of 768
words), 160 requests per arm at concurrency 4, 8 output tokens. Hit rate from
the servers' `vllm:prefix_cache_*` counters; TTFT client-side, streaming.
Medians of 3 repetitions; hit rates listed per repetition.

| Arm | Run | Requests ok | Prefix hit rate | TTFT p50 | TTFT p90 | TTFT mean | Wall per 160 requests |
|---|---|---|---|---|---|---|---|
| service (kube-proxy) | 1 | 480/480 | 0.561, 0.523, 0.598 | 0.584 s | 1.627 s | 0.815 s | 69.4 s |
| service (kube-proxy) | 2 | 480/480 | 0.565, 0.503, 0.497 | 0.923 s | 1.818 s | 0.971 s | 72.9 s |
| random (router, random picker) | 1 | 480/480 | 0.503, 0.515, 0.568 | 0.840 s | 1.783 s | 0.962 s | 77.1 s |
| random (router, random picker) | 2 | 480/480 | 0.549, 0.543, 0.553 | 0.823 s | 1.846 s | 0.937 s | 76.8 s |
| **prefix (router default)** | 1 | 480/480 | **0.802, 0.805, 0.835** | **0.357 s** | **1.232 s** | **0.524 s** | **52.7 s** |
| **prefix (router default)** | 2 | 479/480 | **0.812, 0.834, 0.759** | **0.363 s** | **1.299 s** | **0.534 s** | **52.8 s** |

Prefix routing against the Service, same pods and load:

- prefix-cache hit rate **0.81 against 0.54** (medians of the 6 repetitions, 1.5x);
- TTFT p50 **0.36 s against 0.58-0.92 s** (-39 % and -61 %), mean -36 % and -45 %;
- the same 160 requests take **52.8 s against 69-73 s** (-24 % to -28 %): with
  fewer prefills the same 4 cores serve the load faster;
- requests per replica stayed within 74-86 of 160 in every prefix run (no hot spot).

The prefix arm is the steadiest number of the set (p50 0.357 and 0.363 s);
the Service and random arms move by up to 0.34 s between runs, because which
replica a group lands on is left to chance.

## llm-d-inference-sim v1.2.0, 4 replicas (run 45290650216)

Same cache per replica (4352 tokens), 16 groups, 800 requests per arm at
concurrency 16. The simulator's TTFT is computed from its own cache hits
(200 us per uncached token), so only the hit rate and the spread are results.

| Arm | Requests ok | Prefix hit rate | Requests per replica (rep 1) |
|---|---|---|---|
| service | 2400/2400 | 0.319, 0.320, 0.291 | 188, 194, 212, 206 |
| random | 2400/2400 | 0.311, 0.324, 0.309 | 208, 202, 193, 197 |
| **prefix** | 2400/2400 | **0.688, 0.601, 0.669** | 209, 206, 188, 197 |

With 4 replicas a random pick lands on the replica holding the prefix less
often, so the gap widens: **0.67 against 0.32 (2.1x)**, against 1.5x with 2
replicas. TTFT p50 of the random arm minus the service arm: 0.170 - 0.169 s,
about 1 ms for the extra hop through Envoy and the EPP when the node has spare CPU.

## Hypotheses

| # | Hypothesis | Result |
|---|---|---|
| H1 | prefix hit rate at least 2x the service hit rate, on both backends | **confirmed on the simulator (2.1x), not on vLLM (1.5x)**: with 2 replicas the Service already lands about half of the requests on the replica holding the prefix, so the room for 2x is not there; the TTFT gain is (H2) |
| H2 | on vLLM, prefix TTFT p50 at least 30 % lower than service | **confirmed**: -39 % and -61 % in two runs |
| H3 | random TTFT p50 within 10 % of service, hit rates within 0.05 | **not settled on vLLM**: +44 % in run 1, -11 % in run 2, inside the run-to-run spread of these two arms; hit rates within 0.05 in both. **Confirmed on the simulator** (about 1 ms) |
| H4 | no request fails; no replica gets more than 2x another under prefix routing | **spread confirmed** (max/min at most 1.16); **1 failure in 2880 vLLM requests**: in run 2 one prefix-arm request got Envoy's 503 "upstream connect error ... connection termination". No failure in the 2400 simulator requests of each arm |

## Findings

1. **Out of the box, the router routes by prefix.** The default plugin set of
   v1.0.0 (queue 2, kv-cache-utilization 2, prefix-cache 3), with no
   tokenizer sidecar and no tuning, raised the hit rate measured by the
   servers from 0.54 to 0.81 and cut TTFT p50 by 39-61 % on CPU.
2. **The gain grows with the number of replicas.** With N replicas a
   prefix-blind pick hits the right replica about 1/N of the time:
   1.5x with 2, 2.1x with 4 (simulator).
3. **The router's CPU is not free on a small node.** On vLLM, where the two
   engines use all 4 cores, the random-picker arm (router without affinity)
   was not consistently close to the Service (+44 %, then -11 %). On a real
   cluster the EPP and the proxy run on their own CPU; on EKS they go on the
   system pool, not on the inference nodes.
4. **One 503 from Envoy** ("connection termination" before headers) in the
   prefix arm of run 2. The router's Envoy has no retry policy for a request
   that never reached the engine. Follow-up together with ROADMAP step 6
   (D-0164: retry only when the connection never started).

## Invalid runs, kept on record

- **Simulator, run 45287556802:** 351, 227 and 56 of the 2400 requests of the
  service, random and prefix arms failed with 500 "the kv cache does not have
  sufficient capacity to store this request". With `--max-num-seqs 8` and a
  4352-token cache, 8 requests of ~830 tokens do not fit at once, and the
  simulator rejects instead of queueing as vLLM does. Fixed with
  `--max-num-seqs 4` before run 45290650216; the hit rates of the invalid
  run point the same way (0.37 against 0.74), but are not used.
- **Set-up errors before any measurement** (no number produced): the
  simulator needs `POD_IP` with `--enable-kvcache`; vLLM v0.34.0 CPU
  attention needs a block size multiple of 32 (16 was refused: the cache
  became 136 blocks of 32, same 4352 tokens); a placeholder that was a prefix
  of a variable name corrupted the model revision; a rollout restart left
  terminating pods in the list of pods to scrape.

## Limits

- CPU, a 0.5B model, 8 output tokens: the TTFT gain here is a CPU prefill
  gain. On a GPU prefill is much faster per token, so the absolute gain per
  request is smaller unless prompts are longer. No GPU number follows from this.
- The cache was cut to 4352 tokens per replica so that 8 prompts overflow one
  replica; at the default 1 GiB the same effect needs about 100 distinct long
  prompts. The ratio of working set to cache is what the result depends on.
- One node, so no network hop between replicas and no node failure.
- Router v1.0.0. The endpoint-attribute scorers (llm-d-router #2059) are on
  `main` only and were not measured here.
