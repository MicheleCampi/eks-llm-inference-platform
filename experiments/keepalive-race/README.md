# Envoy 503 "connection termination": the keep-alive race, reproduced without a cluster

Written 2026-11-26, after a pilot and before the measured runs. Results go to
`docs/evidence/keepalive-race-<date>.md`; this file is not edited to fit them.

## Why a second experiment

[`../prefix-routing/KEEPALIVE.md`](../prefix-routing/KEEPALIVE.md) (eks #94)
could not show the race: at concurrency 4 with back-to-back requests a pooled
connection is rarely idle for exactly the server's keep-alive timeout, so the
failure stays at about 1 in 500 to 1 in 3000 whatever the timeout. Live A-025
saw the same failure on EKS (1 of 1920, flag `UC`,
`upstream_reset_before_response_started{connection_termination}`, 2 ms).

This experiment controls the idle time directly. One client connection, so
one Envoy worker and one pooled upstream connection; before each request the
client waits a gap drawn uniformly from a window. When the window sits just
below the server's keep-alive timeout, the server closes the connection as
idle at about the moment Envoy writes the next request on it.

## Set-up

| Part | What |
|---|---|
| Proxy | Envoy `distroless-v1.40.2` (llm-d-router main at 32a075e2) and `distroless-v1.33.2` (chart v1.0.0), `--concurrency 8` as in the chart. Listener, route and `original_destination_cluster` copied from the chart (`envoy.py`), without ext_proc: the client sets `x-gateway-destination-endpoint` as the EPP would |
| Server | `server.py`: FastAPI on uvicorn with `timeout_keep_alive` from `VLLM_HTTP_TIMEOUT_KEEP_ALIVE`, the way vLLM v0.34.0 starts its API server (`vllm/entrypoints/launchers/api_server/entry.py`); 20 ms per request; versions in `requirements.txt` |
| Client | `client.py`: aiohttp, one connection, gap before every request |
| Where | one machine, loopback, no cluster, no model, zero cost |

Pilot (not counted): chart arm, keep-alive 1 s, gaps 0.97 to 1.03 s, 300
requests: 3 failures, all `UC` `connection_termination`, all with a gap
between 0.995 and 0.998 s. The measured windows below are set from it.

Keep-alive 1 s is used for most arms so a run takes minutes; arm D repeats
the key comparison at the vLLM default of 5 s. vLLM takes the value as an
integer number of seconds; the mechanism does not depend on it.

## Arms

| Arm | Envoy config | Keep-alive | Gap window (s) | Requests |
|---|---|---|---|---|
| A1 | chart | 1 s | 0.993 to 0.999 | 300 |
| A2 | chart, Envoy v1.33.2 | 1 s | 0.993 to 0.999 | 300 |
| B1 | upstream `idle_timeout` 0.5 s | 1 s | 0.993 to 0.999 | 300 |
| B2 | route `retry_on: reset`, 1 retry | 1 s | 0.993 to 0.999 | 300 |
| B3 | route `retry_on: reset-before-request`, 1 retry | 1 s | 0.993 to 0.999 | 300 |
| C1 | chart | 1 s | 0.5 to 0.9 | 300 |
| C2 | chart | 1 s | 1.05 to 1.5 | 300 |
| D1 | chart | 5 s | 4.993 to 4.999 | 120 |
| D2 | upstream `idle_timeout` 4 s | 5 s | 4.993 to 4.999 | 120 |

The first request of every arm only opens the connection and is not counted.

## Hypotheses

| # | Hypothesis |
|---|---|
| H1 | A1 and A2: at least 10 % of requests fail, every failure a 503 with flag `UC` and `connection_termination`, in at most 5 ms |
| H2 | C1 and C2: 0 failures (a gap well below the timeout reuses a live connection; a gap well above it finds the close already seen by Envoy) |
| H3 | D1: at least 5 % of requests fail, as H1 |
| H4 | B1 and D2: 0 failures |
| H5 | B2: 0 failures seen by the client, and Envoy logs requests with 2 attempts |
| H6 | B3: no prediction; Envoy documents `reset-before-request` as a retry only when no request headers were sent, which may not cover this race |

If H1 to H4 hold, the 503 of eks #89/#93/#94 and of A-025 has a mechanism
that matches it (same flag, details and duration), and the standard remedy
for a proxy in front of a server with a keep-alive timeout, an upstream idle
timeout below the server's, removes it. A kind run with real vLLM is still
needed before any claim about vLLM itself (next section).

## Then: real vLLM on kind

The arms that matter (chart, idle timeout, retry) are repeated against vLLM
CPU v0.34.0 on kind behind the real chart (EPP and ext_proc included), with
the same gap window at the vLLM default keep-alive, in the
`keepalive-race` workflow. Protocol in [KIND.md](KIND.md).

## Run

    pip install -r requirements.txt
    bash run.sh chart A1 1 0.993 0.999 301
    IDLE_S=0.5 bash run.sh idle B1 1 0.993 0.999 301
