#!/usr/bin/env python3
"""Report of experiments/autoscaling-knee (README.md): per job and rep, the
budget over the window and per segment, good tokens, replica-seconds, EUR
per million good tokens, scale-up time, the share of the high segment with
2 Ready replicas and the scale-downs in it; then H1-H4 against their written
thresholds, each comparison inside one job.
Usage: report.py RESULTS_DIR [RESULTS_DIR ...]   (one directory per job)
       report.py --one RESULTS_DIR/NAME           (one line, after a rep)"""
import datetime as dt
import glob
import json
import os
import sys

USD_PER_REPLICA_H = 0.1067     # step 7 reference price, 2 vCPU on demand, eu-west-1
EUR_PER_USD = float(os.environ.get("EUR_PER_USD", "0.86"))
BUDGET = 0.01
SEGMENTS = [("low1", 0, 300), ("high", 300, 900), ("low2", 900, 1200)]


def rep(base):
    meta = json.load(open(base + ".meta.json"))
    rows, summary = [], {}
    for line in open(base + ".jsonl"):
        if line.startswith('{"req"'):
            rows.append(json.loads(line)["req"])
        elif line.startswith('{"summary"'):
            summary = json.loads(line)["summary"]
    t0 = dt.datetime.strptime(meta["started"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
    wall = summary.get("wall_s") or 1200
    samples = []
    for line in open(base + ".samples"):
        f = line.split()
        if len(f) < 3:
            continue
        rel = int(f[0]) - t0
        desired = int(f[3]) if len(f) > 3 and f[3].isdigit() else None
        samples.append((rel, int(f[1]), int(f[2] or 0), desired))
    win = [s for s in samples if 0 <= s[0] <= wall]
    rs = 0.0
    for a, b in zip(win, win[1:]):
        rs += (b[0] - a[0]) * a[1]
    budget = lambda xs: (sum(not r["good"] for r in xs) / len(xs)) / BUDGET if xs else None
    seg = {n: budget([r for r in rows if r.get("offset") is not None and a <= r["offset"] < b]) for n, a, b in SEGMENTS}
    high = [s for s in win if 300 <= s[0] < 900]
    up = next((s[0] - 300 for s in win if s[0] >= 300 and s[2] >= 2), None)
    asked = next((s[0] for s in win if s[3] is not None and s[3] >= 2), None)
    ready_after_ask = next((s[0] - asked for s in win if asked is not None and s[0] >= asked and s[2] >= 2), None)
    downs = sum(1 for a, b in zip(high, high[1:]) if a[1] >= 2 and b[1] < 2)
    gt = sum(r.get("completion_tokens") or 0 for r in rows if r["good"])
    eur = USD_PER_REPLICA_H * EUR_PER_USD * rs / 3600
    return {
        "name": meta["name"], "arm": meta["arm"], "threshold": meta.get("threshold"), "restarts": meta.get("restarts"),
        "requests": len(rows), "good": sum(r["good"] for r in rows), "budget": budget(rows), "seg": seg,
        "good_tokens": gt, "replica_s": round(rs), "eur_per_mgood": eur / gt * 1e6 if gt else None,
        "up_s": up, "ready_after_ask_s": ready_after_ask,
        "high_2ready": sum(s[2] >= 2 for s in high) / len(high) if high else None, "high_downs": downs,
        "codes": {str(c): sum(1 for r in rows if r.get("code") == c) for c in sorted({r.get("code") for r in rows}, key=str)},
    }


def f(x, pct=False):
    if x is None:
        return "n/a"
    return f"{x * 100:.0f} %" if pct else (f"{x:.2f}" if isinstance(x, float) else str(x))


def table(rows):
    print("| rep | arm | threshold | requests | good | budget | low1 / high / low2 | good tokens | replica-s | EUR per M good tokens | up (s) | asked to Ready (s) | high at 2 Ready | downs in high | restarts | codes |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        s = r["seg"]
        print(f"| {r['name']} | {r['arm']} | {f(r['threshold'])} | {r['requests']} | {r['good']} | {f(r['budget'], True)} | "
              f"{f(s['low1'], True)} / {f(s['high'], True)} / {f(s['low2'], True)} | {r['good_tokens']} | {r['replica_s']} | "
              f"{f(r['eur_per_mgood'])} | {f(r['up_s'])} | {f(r['ready_after_ask_s'])} | {f(r['high_2ready'], True)} | "
              f"{r['high_downs']} | {r['restarts']} | {r['codes']} |")


def hypotheses(jobs):
    h = {k: [] for k in ("H1", "H2", "H3", "H4")}
    restarts = 0
    for job, rows in sorted(jobs.items()):
        by = {r["arm"]: r for r in rows}
        restarts += sum(r["restarts"] or 0 for r in rows)
        s, kn, li = by.get("static2"), by.get("knee"), by.get("little")
        if s and kn:
            ok = (kn["high_2ready"] or 0) < 0.5 and (kn["seg"]["high"] or 0) >= 2 * (s["seg"]["high"] or 0)
            h["H1"].append((ok, f"{job}: knee at 2 Ready {f(kn['high_2ready'], True)} of high (limit < 50 %), high budget {f(kn['seg']['high'], True)} vs static2 {f(s['seg']['high'], True)} (limit >= 2 x)"))
        if s and li:
            ok = (li["high_2ready"] or 0) >= 0.7 and (li["budget"] or 0) <= 2 * (s["budget"] or 0)
            h["H2"].append((ok, f"{job}: little at 2 Ready {f(li['high_2ready'], True)} of high (limit >= 70 %), budget {f(li['budget'], True)} vs static2 {f(s['budget'], True)} (limit <= 2 x)"))
            ok = li["eur_per_mgood"] is not None and s["eur_per_mgood"] is not None and li["eur_per_mgood"] <= 0.9 * s["eur_per_mgood"]
            h["H3"].append((ok, f"{job}: little {f(li['eur_per_mgood'])} vs static2 {f(s['eur_per_mgood'])} EUR per M good tokens (limit 0.9 x)"))
        if li:
            ok = li["up_s"] is not None and li["up_s"] <= 240
            h["H4"].append((ok, f"{job}: little second replica Ready {f(li['up_s'])} s after the step (limit 240 s)"))
    for k, rs in h.items():
        verdict = "holds" if rs and all(ok for ok, _ in rs) else "refuted" if rs else "not evaluated"
        print(f"- {k} ({verdict}): " + "; ".join(t for _, t in rs))
    print(f"- model container restarts: {restarts}")


def main():
    if sys.argv[1] == "--one":
        r = rep(sys.argv[2])
        print(json.dumps({k: r[k] for k in ("name", "arm", "threshold", "budget", "seg", "good_tokens", "replica_s",
                                              "eur_per_mgood", "up_s", "high_2ready", "high_downs", "restarts", "codes")}))
        return
    jobs = {}
    for d in sys.argv[1:]:
        rows = [rep(m[:-len(".meta.json")]) for m in sorted(glob.glob(f"{d}/*.meta.json"))]
        if rows:
            jobs[os.path.basename(os.path.normpath(d))] = rows
    print("# Autoscaling at the measured capacity\n")
    print(f"Price {USD_PER_REPLICA_H} USD per replica-hour x {EUR_PER_USD} EUR/USD; budget {BUDGET:.0%} of requests; "
          "segments low1 0-300 s, high 300-900 s, low2 900-1200 s.\n")
    for d in sys.argv[1:]:
        p = os.path.join(d, "little.json")
        if os.path.exists(p):
            print(f"L ({os.path.basename(os.path.normpath(d))}): {json.load(open(p))}\n")
    for job, rows in sorted(jobs.items()):
        print(f"## {job}\n")
        table(rows)
        print()
    hypotheses(jobs)


if __name__ == "__main__":
    main()
