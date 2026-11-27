#!/usr/bin/env python3
"""Open-loop replay of a schedule against one entry point, inside the cluster
(a pod, so the Service arm goes through kube-proxy as a client would).
Standard library only.

Modes:
  --schedule FILE        open loop: each request is sent at its offset, whatever
                         is still running (production traffic does not wait)
  --closed N             closed loop, one request at a time, N requests with the
                         lengths in --lengths FILE (calibration of T and P)
  --poisson RATE --duration S
                         open loop, Poisson arrivals at RATE req/s, lengths drawn
                         from --lengths FILE (calibration of the capacity C)

Every request asks for exactly `generated` tokens (ignore_eos) and a prompt of
`context` words; the server's own prompt token count is recorded (usage).
TTFT = first data chunk; TPOT = (end - first chunk) / (completion tokens - 1).
A request is good if HTTP 200, a first chunk arrived, TTFT <= --ttft-slo and,
when it has more than one output token, TPOT <= --tpot-slo.

--tenants premium=0.3,batch (finops-guardrail): each request is assigned a
tenant with those probabilities (the rest to the last name, seeded apart
from the prompts) and sends it in `x-llm-d-inference-objective`; the tenant
and the router's `x-llm-d-flow-queue-duration-ms` response header are
recorded. Without the flag nothing changes.

Output: one JSON line per request ("req") and one summary ("summary").
"""
import argparse
import concurrent.futures as cf
import http.client
import json
import math
import random
import threading
import time
import urllib.parse

WORDS = (
    "cluster node pod replica service gateway router prefix cache token model "
    "request latency budget quota tenant region zone spot capacity scheduler "
    "queue kernel memory block policy cost alert probe rollout canary release "
    "image digest chart value secret network ingress egress volume storage disk "
    "metric trace span log event signal error retry backoff timeout drain "
    "taint label selector owner team project account invoice credit forecast "
    "decode prefill batch stream engine worker thread core socket host guest "
    "upgrade version pin patch review merge branch commit test suite runner"
).split()


def prompt(i, n_words, rnd):
    # The request number comes first, so no two prompts share a first cache
    # block: prefix caching plays no part (README "Traffic source").
    return f"Request {i}. " + " ".join(rnd.choice(WORDS) for _ in range(max(1, n_words)))


def one(url, model, text, gen, tenant=None):
    u = urllib.parse.urlparse(url)
    body = json.dumps({
        "model": model, "prompt": text, "max_tokens": gen, "min_tokens": gen,
        "temperature": 0, "stream": True, "ignore_eos": True,
        "stream_options": {"include_usage": True},
    })
    t0 = time.perf_counter()
    ttft, usage = None, None
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=600)
    try:
        headers = {"Content-Type": "application/json"}
        if tenant:
            headers["x-llm-d-inference-objective"] = tenant
        conn.request("POST", "/v1/completions", body, headers)
        resp = conn.getresponse()
        queue_ms = resp.getheader("x-llm-d-flow-queue-duration-ms")
        if resp.status != 200:
            r = {"code": resp.status, "error": resp.read(300).decode(errors="replace"),
                 "e2e": time.perf_counter() - t0}
            if queue_ms is not None:
                r["queue_ms"] = queue_ms
            return r
        while True:
            line = resp.readline()
            if not line:
                break
            if not line.startswith(b"data:") or line.startswith(b"data: [DONE]"):
                continue
            if ttft is None:
                ttft = time.perf_counter() - t0
            try:
                d = json.loads(line[5:])
                if d.get("usage"):
                    usage = d["usage"]
            except ValueError:
                pass
        e2e = time.perf_counter() - t0
    except Exception as exc:  # recorded, not raised: a failed request is a result
        return {"code": 0, "error": str(exc)[:200], "e2e": time.perf_counter() - t0}
    finally:
        conn.close()
    r = {"code": 200, "ttft": ttft, "e2e": e2e}
    if queue_ms is not None:
        r["queue_ms"] = queue_ms
    if usage:
        r["prompt_tokens"] = usage.get("prompt_tokens")
        r["completion_tokens"] = usage.get("completion_tokens")
    ct = r.get("completion_tokens") or gen
    if ttft is not None and ct > 1:
        r["tpot"] = (e2e - ttft) / (ct - 1)
    return r


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, math.ceil(p / 100 * len(xs)) - 1)], 4)


def good(r, t, p):
    if r.get("code") != 200 or r.get("ttft") is None:
        return False
    if t is not None and r["ttft"] > t:
        return False
    if p is not None and r.get("tpot") is not None and r["tpot"] > p:
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--schedule")
    ap.add_argument("--lengths")
    ap.add_argument("--closed", type=int, default=0)
    ap.add_argument("--poisson", type=float, default=0)
    ap.add_argument("--duration", type=float, default=60)
    ap.add_argument("--ttft-slo", type=float)
    ap.add_argument("--tpot-slo", type=float)
    ap.add_argument("--seed", type=int, default=20261126)
    ap.add_argument("--workers", type=int, default=512)
    ap.add_argument("--tenants", default="")
    a = ap.parse_args()
    rnd = random.Random(a.seed)

    meta = {}
    if a.schedule:
        s = json.load(open(a.schedule))
        meta, plan = s["meta"], [(r[0], r[1], r[2]) for r in s["requests"]]
        mode = "schedule"
    else:
        pairs = json.load(open(a.lengths))
        if a.closed:
            plan = [(None, *pairs[i % len(pairs)]) for i in range(a.closed)]
            mode = "closed"
        else:
            plan, t = [], 0.0
            while True:
                t += rnd.expovariate(a.poisson)
                if t >= a.duration:
                    break
                plan.append((t, *rnd.choice(pairs)))
            mode = "poisson"
    texts = [prompt(i, c, rnd) for i, (_, c, _) in enumerate(plan)]
    tenants = [None] * len(plan)
    if a.tenants:
        mix = [(n, float(p)) for n, p in (x.split("=") for x in a.tenants.split(",")[:-1])]
        last = a.tenants.split(",")[-1].split("=")[0]
        trnd = random.Random(a.seed + 1)
        for i in range(len(plan)):
            u, acc, tenants[i] = trnd.random(), 0.0, last
            for n, p in mix:
                acc += p
                if u < acc:
                    tenants[i] = n
                    break

    rows, lock = [], threading.Lock()

    def run(i, offset, ctx, gen, sent_at):
        r = one(a.url, a.model, texts[i], gen, tenants[i])
        if tenants[i]:
            r["tenant"] = tenants[i]
        r.update(arm=a.arm, i=i, offset=offset, context=ctx, generated=gen,
                 lag=round(sent_at - offset, 4) if offset is not None else None)
        r["good"] = good(r, a.ttft_slo, a.tpot_slo)
        with lock:
            rows.append(r)
            print(json.dumps({"req": r}), flush=True)

    t0 = time.perf_counter()
    if mode == "closed":
        for i, (_, c, g) in enumerate(plan):
            run(i, None, c, g, None)
    else:
        with cf.ThreadPoolExecutor(a.workers) as ex:
            for i, (off, c, g) in enumerate(plan):
                d = off - (time.perf_counter() - t0)
                if d > 0:
                    time.sleep(d)
                ex.submit(run, i, off, c, g, time.perf_counter() - t0)
    wall = time.perf_counter() - t0

    ok = [r for r in rows if r.get("code") == 200 and r.get("ttft") is not None]
    gd = [r for r in rows if r["good"]]
    lags = [r["lag"] for r in rows if r.get("lag") is not None]
    bad = len(rows) - len(gd)
    summary = {
        "arm": a.arm, "mode": mode, "meta": meta, "rate": a.poisson or None,
        "requests": len(rows), "ok": len(ok), "failed": len(rows) - len(ok), "good": len(gd),
        "good_fraction": round(len(gd) / len(rows), 5) if rows else None,
        "budget_burned": round((bad / len(rows)) / 0.01, 3) if rows else None,
        "ttft_slo": a.ttft_slo, "tpot_slo": a.tpot_slo,
        "ttft_p50": pct([r["ttft"] for r in ok], 50), "ttft_p95": pct([r["ttft"] for r in ok], 95),
        "ttft_p99": pct([r["ttft"] for r in ok], 99),
        "tpot_p50": pct([r["tpot"] for r in ok if "tpot" in r], 50),
        "tpot_p95": pct([r["tpot"] for r in ok if "tpot" in r], 95),
        "completion_tokens": sum(r.get("completion_tokens") or 0 for r in ok),
        "good_completion_tokens": sum(r.get("completion_tokens") or 0 for r in gd),
        "prompt_tokens": sum(r.get("prompt_tokens") or 0 for r in ok),
        "prompt_words": sum(r["context"] for r in ok),
        "dispatch_lag_p99": pct(lags, 99), "wall_s": round(wall, 2),
        "failures": dict(__import__("collections").Counter(
            f'{r["code"]} {r.get("error", "")}'.strip()[:120] for r in rows if r not in ok)),
    }
    print(json.dumps({"summary": summary}), flush=True)


if __name__ == "__main__":
    main()
