#!/usr/bin/env python3
"""Turn an Azure LLM inference trace (CSV: TIMESTAMP, ContextTokens,
GeneratedTokens) into a replay schedule, with the fixed rules of README.md.
Runs on the runner, standard library only.

  trace.py stats    CSV                       rows, span, rate, busiest minute, quantiles
  trace.py window   CSV OUT                   20-minute window around the busiest minute,
                                              lengths scaled (README "Scaling rules")
  trace.py thin     WINDOW RATE SEED OUT      keep each arrival with p = RATE / mean rate
                                              (p > 1: compress time by p instead)
  trace.py lengths  WINDOW N SEED OUT         N (context, generated) pairs for calibration

Schedules are JSON: {"meta": {...}, "requests": [[offset_s, context, generated], ...]}.
"""
import collections
import csv
import datetime as dt
import json
import random
import sys

LENGTH_DIVISOR = 8      # README: context and generated tokens divided by 8, minimum 1
WINDOW_S = 20 * 60      # README: 20 minutes containing the busiest minute
MAX_MODEL_LEN = 2048    # vLLM --max-model-len of the backend (prefix-routing manifest)
PROMPT_MARGIN = 48      # tokens kept free for the prompt's header and the template


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            # TIMESTAMP has 7 fractional digits; Python parses at most 6.
            ts = dt.datetime.fromisoformat(r["TIMESTAMP"][:26])
            rows.append((ts, int(r["ContextTokens"]), int(r["GeneratedTokens"])))
    rows.sort(key=lambda x: x[0])
    return rows


def q(xs, p):
    xs = sorted(xs)
    return xs[int(p * (len(xs) - 1))]


def busiest_minute(rows):
    per_min = collections.Counter(t.replace(second=0, microsecond=0) for t, _, _ in rows)
    m, n = max(per_min.items(), key=lambda kv: (kv[1], kv[0]))
    return m, n, per_min


def stats(rows):
    span = (rows[-1][0] - rows[0][0]).total_seconds()
    m, n, per_min = busiest_minute(rows)
    return {
        "rows": len(rows), "start": rows[0][0].isoformat(), "end": rows[-1][0].isoformat(),
        "span_s": round(span, 1), "mean_rps": round(len(rows) / span, 3),
        "busiest_minute": m.isoformat(), "busiest_minute_requests": n,
        "quietest_minute_requests": min(per_min.values()),
        "context_p50_p90_p99": [q([c for _, c, _ in rows], p) for p in (.5, .9, .99)],
        "generated_p50_p90_p99": [q([g for _, _, g in rows], p) for p in (.5, .9, .99)],
    }


def scale(ctx, gen):
    """Lengths divided by LENGTH_DIVISOR (minimum 1), then clipped so that the
    request fits the backend's context window. Clipping is counted."""
    c = max(1, round(ctx / LENGTH_DIVISOR))
    g = max(1, round(gen / LENGTH_DIVISOR))
    clipped = False
    if c + g > MAX_MODEL_LEN - PROMPT_MARGIN:
        c = max(1, MAX_MODEL_LEN - PROMPT_MARGIN - g)
        clipped = True
    return c, g, clipped


def window(rows):
    """The WINDOW_S seconds that contain the busiest minute, centred on it and
    shifted to stay inside the trace."""
    m, n, _ = busiest_minute(rows)
    t0, t_end = rows[0][0], rows[-1][0]
    start = m + dt.timedelta(seconds=30) - dt.timedelta(seconds=WINDOW_S / 2)
    start = max(t0, min(start, t_end - dt.timedelta(seconds=WINDOW_S)))
    end = start + dt.timedelta(seconds=WINDOW_S)
    reqs, clipped = [], 0
    for t, c, g in rows:
        if start <= t < end:
            sc, sg, cl = scale(c, g)
            clipped += cl
            reqs.append([round((t - start).total_seconds(), 4), sc, sg])
    meta = {
        "window_start": start.isoformat(), "window_s": WINDOW_S,
        "busiest_minute": m.isoformat(), "busiest_minute_requests": n,
        "requests": len(reqs), "mean_rps": round(len(reqs) / WINDOW_S, 4),
        "length_divisor": LENGTH_DIVISOR, "max_model_len": MAX_MODEL_LEN, "clipped": clipped,
    }
    return {"meta": meta, "requests": reqs}


def thin(sched, rate, seed):
    """Keep each arrival with probability rate / mean rate (seeded): the mean
    offered rate becomes `rate` and the burst shape is kept."""
    mean = sched["meta"]["mean_rps"]
    p = rate / mean
    if p <= 1:
        rnd = random.Random(seed)
        kept = [r for r in sched["requests"] if rnd.random() < p]
        span, speedup = sched["meta"]["window_s"], 1.0
    else:
        # README amendment 1: the capacity is above the window's mean rate, so
        # nothing can be thinned; time is compressed by p instead, which keeps
        # every arrival and the burst shape, and shortens the window.
        kept = [[round(r[0] / p, 4), r[1], r[2]] for r in sched["requests"]]
        span, speedup = sched["meta"]["window_s"] / p, p
    meta = dict(sched["meta"], target_rps=rate, keep_probability=round(min(p, 1), 6),
                time_speedup=round(speedup, 4), seed=seed, replay_s=round(span, 1),
                requests=len(kept), mean_rps=round(len(kept) / span, 4))
    return {"meta": meta, "requests": kept}


def lengths(sched, n, seed):
    rnd = random.Random(seed)
    return [[r[1], r[2]] for r in rnd.sample(sched["requests"], n)]


def main():
    cmd = sys.argv[1]
    if cmd == "stats":
        print(json.dumps(stats(load(sys.argv[2]))))
    elif cmd == "window":
        s = window(load(sys.argv[2]))
        json.dump(s, open(sys.argv[3], "w"))
        print(json.dumps(s["meta"]))
    elif cmd == "thin":
        s = thin(json.load(open(sys.argv[2])), float(sys.argv[3]), int(sys.argv[4]))
        json.dump(s, open(sys.argv[5], "w"))
        print(json.dumps(s["meta"]))
    elif cmd == "lengths":
        out = lengths(json.load(open(sys.argv[2])), int(sys.argv[3]), int(sys.argv[4]))
        json.dump(out, open(sys.argv[5], "w"))
        print(json.dumps({"pairs": len(out)}))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
