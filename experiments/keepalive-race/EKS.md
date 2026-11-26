# The keep-alive race on EKS: the kind result with a real network

Written 2026-11-26, before the session (live A-026,
[runbook](../../docs/runbooks/live-a026.md)). Results go to
`docs/evidence/live-a026-<date>.md`; this file is not edited to fit them.

## Question

On kind, the chart's Envoy config failed 2 of 240 requests with a 503
`UC` `connection_termination` when the pooled connection idled for 4.90 to
5.00 s against vLLM's 5 s keep-alive, and an upstream idle timeout of 4 s
removed it (0 of 240; [evidence](../../docs/evidence/keepalive-race-2026-11-26.md),
K3-K4). In live A-025 the same failure happened once in 1920 requests on
EKS ([evidence](../../docs/evidence/live-a025-2026-11-25.md), E5). Every
router install of this repository now carries the 4 s timeout. On EKS:

1. Does the race show up with the router and the model on separate nodes,
   a real network between them (arm `chart`)?
2. Does the 4 s idle timeout remove it there too (arm `idle`)?

## Set-up

| | |
|---|---|
| Platform | eks-llm-inference-platform **v2.4.3** (operator v0.18.0), eu-west-1, as in A-025 |
| Model servers | `eks/model.yaml`: one VllmService `qwen-race` per arm, **1 replica**, in namespaces `race-chart` and `race-idle`; vLLM CPU **v0.34.0** by digest, Qwen2.5-0.5B-Instruct at the pinned revision, `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=5` (the default, written out), no reserved CPU; m7i-flex.large, recorded per replica |
| Router | llm-d-router-standalone chart from llm-d-router **main at 32a075e2**, EPP from llm-d's per-commit build by digest, Envoy `distroless-v1.40.2`, `legacy` scorer values, the EKS overlay of A-025 (own node, never a model node). Arm `chart`: Envoy config as rendered, plus the attempt count in the access log. Arm `idle`: upstream `idle_timeout: 4s` on `original_destination_cluster` (`../envoy_patch.py idle`, the code every install now runs) |
| Client | `../client.py`, unchanged, in a pod on a non-model node: one connection to `router-epp:8081`, one short prompt, `max_tokens: 1`, gap uniform in **4.90 to 5.00 s**, 241 requests (the first opens the connection and is not counted) |
| Order | Both arms **at the same time**, one per namespace, same seed: the same gaps, the same window of the session |

Each arm has its own model pod, so its EPP has one pod to pick and one
Envoy worker keeps one pooled connection to it; the idle time of that
connection is the client's gap plus the EPP's time and the network round
trip.

## Hypotheses

| # | Hypothesis |
|---|---|
| K6 | `chart`: at least 1 failure in 240, each a 503 with flag `UC` and `connection_termination` in the Envoy access log, upstream = the arm's vLLM pod |
| K7 | `idle`: 0 failures in 240 |

Reading, fixed now:

- K6 and K7 hold: the race and the fix are shown on EKS as on kind; the
  upstream chart change (issue with a PR to follow) carries kind and EKS
  numbers.
- K6 fails (0 failures with the chart's config): on this network the
  window falls outside 4.90-5.00 s (the round trip adds to the idle time).
  Not a failure of the fix; the kind result stands, and K7 is read as a
  no-harm check only. Not re-run with another window in the same session.
- K7 fails: the fix is not complete on EKS; every failure is matched to its
  access-log line before any upstream proposal.

## Limits

- One replica per arm and one client connection: the mechanism under
  control, not the rate under load (A-025: 1 in 1920).
- 240 requests per arm cannot show that a rate of 1 in 1000 is zero; K7 is
  read against K6 in the same window.
- Two arms on two different nodes and pods: CPU recorded per replica.
