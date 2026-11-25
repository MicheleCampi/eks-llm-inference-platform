# Prefix-aware routing on EKS: the kind result on a real cluster

Written 2026-11-25, before the session (live A-025,
[runbook](../../docs/runbooks/live-a025.md)). Results go to
`docs/evidence/live-a025-<date>.md`; this file is not edited to fit them.

## Question

On kind, llm-d-router v1.0.0 with its default configuration raised the
prefix-cache hit rate of 2 vLLM CPU replicas from 0.54 to 0.81 and cut TTFT
p50 by 39-61 % against a plain Service
([evidence](../../docs/evidence/prefix-routing-2026-11-23.md)), and the
endpoint-attribute scorers of llm-d-router #2059 matched the legacy ones
(hit 0.744 against 0.728, TTFT p50 +4 %,
[evidence](../../docs/evidence/scorer-parity-2026-11-25.md)). Everything ran
on one 4-core node. Three things kind cannot show:

1. Does the result hold when the replicas are on **two nodes in two zones**,
   behind the operator's Service and NetworkPolicy, with the router on a
   node of its own and the network in between?
2. Does the **#2059 parity hold on real servers on separate nodes**? The
   maintainer said simulator parity is enough and real servers are
   preferred (llm-d-router #2059, 24/11).
3. Does Envoy's 503 "connection termination" (flag `UC`, 1 in about 1000 to
   3000 requests on kind, [KEEPALIVE.md](KEEPALIVE.md), cause still open)
   appear with a real network between proxy and engine?

## Set-up

| | |
|---|---|
| Platform | eks-llm-inference-platform **v2.4.3** (EKS 1.36, Karpenter 1.15.3, operator v0.18.0), eu-west-1 |
| Model servers | `eks/model.yaml`: VllmService `qwen-prefix`, 2 replicas, `zoneSpread: Required`, vLLM CPU **v0.34.0** by digest, Qwen2.5-0.5B-Instruct at the pinned revision; the engine settings of the kind arm: prefix caching on, cache cut to 4352 tokens (136 blocks of 32), no reserved CPU, dev mode for `/reset_prefix_cache`; keep-alive at the vLLM default 5 s |
| Nodes | Karpenter pool general, m7i-flex.large (2 vCPU, 8 GiB; Xeon 8488C in A-021, A-022), Spot or On-Demand as the pool allows; recorded per replica |
| Router | arms `prefix`: llm-d-router **v1.0.0** chart and EPP by digest, as on kind. Arms `legacy`, `ea`: chart and EPP of llm-d-router `main` at `32a075e2` (the commit of the kind parity run), the EPP image from llm-d's own per-commit build, by digest (`versions.env`). Values: `values/router.yaml`, then `eks/router-eks.yaml` (own node, never a model node; requests for a 2 vCPU node), then the arm's values, unchanged from kind |
| Load | `loadgen.py`, unchanged, in a pod on a non-model node |

The router pod gets the client label of the operator's NetworkPolicy with
`kubectl patch` after the install: the v1.0.0 chart cannot label the EPP
pod (`router.epp.podLabels` exists on main only).

## Arms and order

`service` (the operator's ClusterIP Service, kube-proxy), `prefix`,
`legacy`, `ea`. Three repetitions; repetition 2 in reverse order
(`eks/run.sh all`). Caches emptied and a fresh EPP before every arm. No
`random` arm: on kind the hop cost about 1 ms when the node had spare CPU
(simulator), and here the router has its own node.

## Workload

As the vLLM arm on kind: 8 groups of 768-word system prompts (from the
capacity rule of [README.md](README.md)), a 32-word unique question, 8 output
tokens, 160 requests per arm at concurrency 4, the same seed.

## Hypotheses

| # | Hypothesis | Arms |
|---|---|---|
| E1 | prefix hit rate at least 1.3x the service hit rate (median of 3) | prefix vs service |
| E2 | prefix TTFT p50 at least 30 % lower than service (median of 3) | prefix vs service |
| E3 | #2059 parity, as PARITY.md P1 and P2: median hit rate of ea within 0.03 of legacy, median TTFT p50 of ea within 10 % of legacy | legacy vs ea |
| E4 | under every router arm no replica gets more than 2x the requests of another | prefix, legacy, ea |
| E5 | no request fails; any failure is matched to its Envoy access-log line and response flag | all |

E1 is 1.3x, not the 2x of README H1: with 2 replicas a prefix-blind pick
lands on the right replica about half the time, so kind measured 1.5x and
there is no room for 2x (evidence 2026-11-23, H1).

Reading, fixed now:

- E1 and E2 hold: the kind result holds on EKS across zones; the CV can say
  "measured on EKS", with the CPU and the versions next to the numbers.
- E1 holds and E2 does not: affinity works, but on this network and CPU the
  saved prefill is not visible in TTFT; recorded as such.
- E1 fails: the cross-zone set-up changes what the router sees (scrape
  intervals, queue signals); the EPP logs of the arm are read before any
  claim.
- E3 holds: posted on #2059 as real-server parity, next to the kind and
  simulator numbers. E3 fails: posted as a difference to investigate, with
  the EPP logs, before any deprecation PR.
- E5: a 503 with flag `UC` on EKS shows the race is not a kind artefact;
  together with an idle-gap test on kind (planned, zero cost) it decides whether an upstream
  change to the chart's Envoy cluster (an upstream idle timeout below the
  engines' keep-alive, or a retry on a reset before any byte) is proposed.

## S3'' observation O1: the router during a node shutdown

During S3'' ([s3-node-shutdown-v2.4.3.md](../../docs/gameday/s3-node-shutdown-v2.4.3.md)),
a second probe (`eks/probe-router.yaml`), the same request every 2 s, goes
through the router (v1.0.0, default configuration) to the game day model,
next to the probe through the Service. It changes nothing in the S3''
hypotheses or pass criteria. O1: after the operator deletes the pod on the
shutting-down node, the router stops picking it as fast as the Service does:
first-try availability through the router at least 99.5 % over the S3''
window, and no router answer comes from the deleted pod after its deletion
(Envoy access log, `upstream` address).

## Limits, declared before the run

- CPU, a 0.5B model, 8 output tokens: a CPU prefill gain. No GPU number
  follows.
- 2 replicas on 2 nodes; m7i-flex instances may differ in CPU from node to
  node (recorded per replica) and the flex performance model may vary over
  the session.
- One session, 3 repetitions per arm: the spread between repetitions is
  reported with the medians.
- The router is a single EPP replica with its proxy as a sidecar, no HA.
