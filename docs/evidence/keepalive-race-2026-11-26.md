# Experiment evidence: the Envoy-to-uvicorn keep-alive race (2026-11-26)

Protocols, written before the measured runs:
[`experiments/keepalive-race/README.md`](../../experiments/keepalive-race/README.md)
(stand-in server, no cluster) and
[`KIND.md`](../../experiments/keepalive-race/KIND.md) (real vLLM on kind).
Cost: 0 (one cloud dev container for the stand-in runs, GitHub-hosted
runners for the kind runs, no AWS resources).

The question comes from eks #89, #93, #94 and live A-025: about 1 request in
500 to 3000 through llm-d-router fails with a 503, Envoy flag `UC`,
`upstream_reset_before_response_started{connection_termination}`, after the
EPP has picked the vLLM pod. eks #94 could not show the cause because its
load had no controlled idle gaps.

## Part 1: stand-in server, no cluster

Run on 2026-11-26 between 18:34Z and 18:46Z, all arms side by side on one
machine (Intel Xeon @ 2.10 GHz, 4 CPUs), loopback. Envoy
`distroless-v1.40.2` (A2: `distroless-v1.33.2`), `--concurrency 8`, the
chart's listener, route and `original_destination_cluster` (`envoy.py`).
Server: uvicorn 0.54.0, httptools 0.9.0, uvloop 0.23.0, h11 0.16.0 with
`timeout_keep_alive` as vLLM v0.34.0 sets it. Client: aiohttp 3.14.5, one
connection. FastAPI was 0.165.0 in this run (`requirements.txt` pins 0.136.1,
inside vLLM v0.34.0's range, for later runs); FastAPI is not on the
connection path. Raw data:
[`data/keepalive-race-2026-11-26-local.tar.gz`](data/keepalive-race-2026-11-26-local.tar.gz)
(sha256 `013c584c…87a8`: client JSON lines, Envoy access logs, versions).

| Arm | Envoy config | Keep-alive | Gap (s) | Failed / requests | Failures: flag, details | Gap of the failures (s) |
|---|---|---|---|---|---|---|
| A1 | chart | 1 s | 0.993 to 0.999 | **29 / 300** (9.7 %) | all `UC`, `connection_termination`, 0 ms in Envoy, 1.1 to 2.4 ms at the client | 0.9951 to 0.9979 |
| A2 | chart, Envoy v1.33.2 | 1 s | 0.993 to 0.999 | **33 / 300** (11.0 %) | all `UC`, `connection_termination`, 0 to 1 ms | 0.9961 to 0.9981 |
| B1 | upstream `idle_timeout` 0.5 s | 1 s | 0.993 to 0.999 | **0 / 300** | | |
| B2 | `retry_on: reset`, 1 retry | 1 s | 0.993 to 0.999 | **0 / 300** | 23 requests with 2 attempts, all 200, 22 to 48 ms | |
| B3 | `retry_on: reset-before-request`, 1 retry | 1 s | 0.993 to 0.999 | **33 / 300** (11.0 %) | all `UC`, `connection_termination`, 1 attempt | 0.9960 to 0.9988 |
| C1 | chart | 1 s | 0.5 to 0.9 | 0 / 300 | | |
| C2 | chart | 1 s | 1.05 to 1.5 | 0 / 300 | | |
| D1 | chart | **5 s** (vLLM default) | 4.993 to 4.999 | **7 / 120** (5.8 %) | all `UC`, `connection_termination`, 0 ms | 4.9931 to 4.9939 |
| D2 | upstream `idle_timeout` 4 s | 5 s | 4.993 to 4.999 | **0 / 120** | | |

The first request of every arm opened the connection and is not counted.
A2's two extra failures without an Envoy line are client-side counts of the
same requests (Envoy logged 31 `UC` lines for 33 client failures; not
investigated). B1's Envoy log has 61 `UH no_healthy_upstream` lines between
18:35:31Z and 18:36:01Z that are not B1 requests: the first start of D2 drew
B1's listener port as its admin port and its readiness loop polled it for
30 s (D2 then failed to bind and was re-run alone); B1's client saw 300/300.

### Hypotheses

| # | Hypothesis | Result |
|---|---|---|
| H1 | A1 and A2: ≥ 10 % fail, every failure `UC` `connection_termination` in ≤ 5 ms | **A2 met (11.0 %); A1 missed the threshold by one request (9.7 %)**. The signature part holds for every failure of both |
| H2 | C1 and C2: 0 failures | **met** (0 / 600) |
| H3 | D1 (5 s): ≥ 5 % fail, as H1 | **met** (5.8 %) |
| H4 | B1 and D2: 0 failures | **met** (0 / 420) |
| H5 | B2: 0 failures at the client, retries in the Envoy log | **met** (0 / 300, 23 retried) |
| H6 | B3: no prediction | `reset-before-request` **does not cover** the race: 33 / 300 failed, none retried |

### Reading

- The failure of eks #89/#93/#94 and A-025 has a mechanism that reproduces
  it exactly, with no cluster and no model: the same flag, the same details,
  the same 0 to 2 ms. It happens only when the pooled connection has been
  idle for **between about 3 and 5 ms less than the server's keep-alive
  timeout** (failures between 0.9951 and 0.9988 s at 1 s; 4.9931 to 4.9939
  s at 5 s), never well below it (C1) or above it (C2). In that window the
  server closes the idle connection while Envoy is writing the next request
  on it; Envoy has not yet read the close, so it cannot pick another
  connection, and the request fails before any response byte.
- The chart sets no upstream idle timeout, so Envoy keeps idle connections
  for its default of 1 h and the server is always the side that closes:
  every connection that sits idle for about 5 s is a chance for the race.
  Under prefix-aware routing that is common: with `--concurrency 8` each
  Envoy worker keeps its own connection to each vLLM pod, and the EPP sends a
  worker's requests where the prefix is, so a (worker, pod) connection can
  stay unused for seconds. This explains why the rate is low but not zero
  under continuous load; the rate itself was not modelled.
- **An upstream idle timeout below the server's keep-alive removes the
  failure** (B1, D2: 0 / 420). Envoy then closes first, and never writes on a
  connection the server is closing. This is the standard rule for any proxy
  in front of a server with a keep-alive timeout: the client side of the pool
  must time out first.
- `retry_on: reset` also hides it (B2), at the cost of a second attempt,
  and of retrying a non-idempotent POST if a reset comes after the server
  started work. `reset-before-request`, the narrower retry, does not help
  (B3): Envoy had already sent the request headers. A retry is a second line
  of defence, not the fix.
- Same result on Envoy v1.33.2 (chart v1.0.0) and v1.40.2 (main).

## Part 2: real vLLM on kind

To be added from the `keepalive-race` workflow run (KIND.md, hypotheses K3
to K5), before any claim about vLLM itself.
