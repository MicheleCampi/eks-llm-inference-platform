#!/usr/bin/env python3
"""Shared-prefix load against one entry point, with the model servers' own
prefix-cache counters read before and after.

Runs inside the cluster (a pod), so the Service arm goes through kube-proxy
exactly as a client would: a port-forward would pin every request to one pod.
Standard library only.

Workload: G groups, each with a fixed system prompt of P words, and N requests
that each pick a group at random (seeded, so every arm gets the same sequence)
and add a unique question. G comes from the cache capacity the servers report
(rule in README.md): the working set is 0.75 x capacity x replicas, so it fits
across the replicas only if each replica keeps its own share of the groups.

Output: one JSON line per request ("req") and one summary ("summary").
"""
import argparse
import concurrent.futures as cf
import http.client
import json
import math
import random
import re
import sys
import time
import urllib.parse
import urllib.request

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


def scrape(target):
    """Counters of one model server, summed over label sets."""
    with urllib.request.urlopen(f"http://{target}/metrics", timeout=10) as r:
        text = r.read().decode()
    out = {"hits": 0.0, "queries": 0.0, "success": 0.0, "blocks": None, "block_size": None}
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        m = re.match(r"^([a-zA-Z_:]+)(\{[^}]*\})?\s+([0-9.eE+-]+)", line)
        if not m:
            continue
        name, labels, value = m.group(1), m.group(2) or "", float(m.group(3))
        if name in ("vllm:prefix_cache_hits_total", "vllm:prefix_cache_hits"):
            out["hits"] += value
        elif name in ("vllm:prefix_cache_queries_total", "vllm:prefix_cache_queries"):
            out["queries"] += value
        elif name == "vllm:request_success_total":
            out["success"] += value
        elif name == "vllm:cache_config_info":
            b = re.search(r'num_gpu_blocks="(\d+)"', labels)
            s = re.search(r'block_size="(\d+)"', labels)
            if b and s:
                out["blocks"], out["block_size"] = int(b.group(1)), int(s.group(1))
    return out


def one_request(url, model, prompt, max_tokens):
    u = urllib.parse.urlparse(url)
    body = json.dumps({
        "model": model, "prompt": prompt, "max_tokens": max_tokens,
        "temperature": 0, "stream": True, "ignore_eos": True,
    })
    t0 = time.perf_counter()
    ttft = None
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=300)
    try:
        conn.request("POST", "/v1/completions", body, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        code = resp.status
        if code != 200:
            err = resp.read(300).decode(errors="replace")
            return {"code": code, "error": err, "e2e": time.perf_counter() - t0, "ttft": None}
        while True:
            line = resp.readline()
            if not line:
                break
            if ttft is None and line.startswith(b"data:") and not line.startswith(b"data: [DONE]"):
                ttft = time.perf_counter() - t0
        e2e = time.perf_counter() - t0
    except Exception as exc:  # recorded, not raised: a failed request is a result
        return {"code": 0, "error": str(exc)[:200], "e2e": time.perf_counter() - t0, "ttft": None}
    finally:
        conn.close()
    return {"code": code, "ttft": ttft, "e2e": e2e}


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, math.ceil(p / 100 * len(xs)) - 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--pods", required=True, help="comma-separated ip:port of every model server")
    ap.add_argument("--prefix-words", type=int, default=768)
    ap.add_argument("--question-words", type=int, default=32)
    ap.add_argument("--requests", type=int, default=160)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--max-tokens", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20261123)
    ap.add_argument("--fill", type=float, default=0.75,
                    help="working set as a fraction of the capacity of all replicas")
    ap.add_argument("--capacity-tokens", type=int, default=0,
                    help="per-replica cache capacity when the servers do not report it")
    a = ap.parse_args()

    pods = a.pods.split(",")
    before = {p: scrape(p) for p in pods}
    caps = [b["blocks"] * b["block_size"] for b in before.values() if b["blocks"]]
    capacity = min(caps) if caps else a.capacity_tokens
    if not capacity:
        sys.exit("no cache capacity reported by the servers and none given")
    per_group = a.prefix_words + a.question_words
    groups = max(2, round(a.fill * capacity * len(pods) / per_group))

    rnd = random.Random(a.seed)
    prefixes = [
        f"System prompt of tenant {g}. " + " ".join(rnd.choice(WORDS) for _ in range(a.prefix_words))
        for g in range(groups)
    ]
    plan = []
    for i in range(a.requests):
        g = rnd.randrange(groups)
        q = " ".join(rnd.choice(WORDS) for _ in range(a.question_words))
        plan.append((i, g, f"{prefixes[g]}\nQuestion {i}: {q}\nAnswer:"))

    seen, rows = set(), []
    first_of_group = {}
    for i, g, _ in plan:
        if g not in seen:
            first_of_group[i] = True
            seen.add(g)

    t0 = time.perf_counter()
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        futs = {ex.submit(one_request, a.url, a.model, p, a.max_tokens): (i, g) for i, g, p in plan}
        for f in cf.as_completed(futs):
            i, g = futs[f]
            r = f.result()
            r.update(arm=a.arm, i=i, group=g, first_of_group=first_of_group.get(i, False))
            rows.append(r)
            print(json.dumps({"req": r}), flush=True)
    wall = time.perf_counter() - t0

    time.sleep(2)  # the servers update their counters after the response
    after = {p: scrape(p) for p in pods}
    per_pod = {}
    for p in pods:
        d = {k: after[p][k] - before[p][k] for k in ("hits", "queries", "success")}
        d["hit_rate"] = round(d["hits"] / d["queries"], 4) if d["queries"] else None
        per_pod[p] = d
    hits = sum(d["hits"] for d in per_pod.values())
    queries = sum(d["queries"] for d in per_pod.values())
    ok = [r for r in rows if r["code"] == 200 and r["ttft"] is not None]
    repeat = [r["ttft"] for r in ok if not r["first_of_group"]]
    summary = {
        "arm": a.arm,
        "requests": len(rows), "ok": len(ok), "failed": len(rows) - len(ok),
        "wall_s": round(wall, 2), "concurrency": a.concurrency,
        "replicas": len(pods), "capacity_tokens_per_replica": capacity,
        "groups": groups, "prefix_words": a.prefix_words, "question_words": a.question_words,
        "max_tokens": a.max_tokens, "seed": a.seed,
        "hit_rate": round(hits / queries, 4) if queries else None,
        "failures": dict(__import__("collections").Counter(
            f'{r["code"]} {r.get("error") or ("no data chunk" if r["ttft"] is None else "")}'.strip()
            for r in rows if not (r["code"] == 200 and r["ttft"] is not None))),
        "ttft_p50": pct([r["ttft"] for r in ok], 50), "ttft_p90": pct([r["ttft"] for r in ok], 90),
        "ttft_p99": pct([r["ttft"] for r in ok], 99),
        "ttft_mean": round(sum(r["ttft"] for r in ok) / len(ok), 4) if ok else None,
        "ttft_p50_repeat_group": pct(repeat, 50),
        "e2e_p50": pct([r["e2e"] for r in ok], 50),
        "per_pod": per_pod,
    }
    print(json.dumps({"summary": summary}), flush=True)


if __name__ == "__main__":
    main()
