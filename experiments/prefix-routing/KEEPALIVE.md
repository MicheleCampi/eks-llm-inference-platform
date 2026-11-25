# Envoy 503 "connection termination": idle-connection race, on kind

Written 2026-11-25, before any run. Results go to
`docs/evidence/keepalive-503-<date>.md`; this file is not edited to fit them.

## Question

Two runs failed one request each with Envoy's 503 "upstream connect error or
disconnect/reset before headers. reset reason: connection termination": 1 of
2880 (prefix-routing, 2026-11-23, llm-d-router v1.0.0, legacy scorers) and 1
of 640 (scorer parity, 2026-11-25, llm-d-router main, ea arm). The failed
request of 2026-11-25 failed after 10 ms, after the EPP had picked a pod.

Hypothesis of mechanism: Envoy reuses a pooled upstream connection that vLLM
has just closed as idle. vLLM closes idle connections after
`VLLM_HTTP_TIMEOUT_KEEP_ALIVE` (default 5 s); the chart's
`original_destination_cluster` sets no upstream idle timeout (Envoy's default
is 1 h) and no retry on reset, so the server always closes first and the
request that lands on the closing connection fails.

## Set-up

The scorer-parity set-up (`PARITY.md`), vLLM backend only, both arms
(legacy, ea) 3 times each, order alternated. One job per value of the vLLM
idle timeout; everything else identical:

| condition | `VLLM_HTTP_TIMEOUT_KEEP_ALIVE` | expected server-side idle closes during a run |
|---|---|---|
| short | 1 s | many |
| long | 600 s | none (no arm lasts 600 s, and each arm starts a fresh Envoy) |

Every router container's log is saved per arm, so each failure can be matched
with its Envoy access-log entry and response flags (`UC` = upstream
connection termination).

## Hypotheses

| # | Hypothesis |
|---|---|
| K1 | short: more than 1 failure in 960 requests, every failure with flag `UC` |
| K2 | long: 0 failures in 960 requests |

If K1 fails, the mechanism is not shown by this run and the 503 stays
unexplained. If K1 holds and K2 holds, the cause is the idle-connection race
and the scorer plays no part; the remedy belongs to the proxy configuration
(an upstream idle timeout below the servers' keep-alive, or a retry on
connection reset before headers), not to #2059.

## Limits

- CPU, 2 vLLM replicas, one runner. 960 requests per condition cannot show a
  rate of 1 in 1000 is zero; K2 is read together with K1.
