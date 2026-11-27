#!/usr/bin/env python3
"""Report of the canary experiment (README.md): per job (one runner, its own
calibration and baselines; since amendment 2 every arm runs in each job) and
rep, requests failed, error budget burned over the replay and over the span
from the rollout start, rollout timings and container restarts from the
watcher, per-pod requests and TTFT fraction from Prometheus; then H1-H4
against their written thresholds, each comparison inside one job.
Usage: report.py RESULTS_DIR [RESULTS_DIR ...]   (one directory per job)"""
import glob
import json
import os
import statistics as st
import sys

SLO_BAD = 0.01  # 99 % objective: error budget = 1 % of requests


def arm_of(meta):
    if meta["version"] == "none":
        return "baseline"
    if meta["kind"] == "deployment":
        return "bad-rolling" if meta["version"] == "v2-bad" else "good-rolling"
    return "bad-canary" if meta["version"] == "v2-bad" else "good-canary"


def load_reqs(path):
    reqs = []
    for line in open(path):
        if line.startswith('{"req"'):
            reqs.append(json.loads(line)["req"])
    return reqs


def burned(reqs):
    return (sum(1 for r in reqs if not r["good"]) / len(reqs)) / SLO_BAD if reqs else None


def first(samples, after, cond):
    for s in samples:
        if s["t"] >= after and cond(s):
            return s["t"]
    return None


def serving(s, v):
    return s.get("versions", {}).get(v, {}).get("serving", 0)


def pods(s, v):
    return s.get("versions", {}).get(v, {}).get("pods", 0)


def rep_row(d, meta):
    reqs = load_reqs(f"{d}/{meta['name']}.jsonl")
    offset = (meta["trigger"] - meta["replay_start"]) if meta["trigger"] else meta["trigger_s"]
    span = [r for r in reqs if r["offset"] >= offset]
    row = {"name": meta["name"], "arm": arm_of(meta), "requests": len(reqs),
           "failed": sum(1 for r in reqs if r.get("code") != 200 or r.get("ttft") is None),
           "budget": burned(reqs), "budget_span": burned(span), "span_from_s": round(offset, 1),
           "span_requests": len(span)}
    wpath = f"{d}/{meta['name']}.watch.jsonl"
    if meta["trigger"] and os.path.exists(wpath):
        w = [json.loads(l) for l in open(wpath)]
        t0 = meta["trigger"]
        ready = first(w, t0, lambda s: serving(s, "v2") >= 1)
        row["canary_ready_s"] = round(ready - t0, 1) if ready else None
        if meta["kind"] == "rollout":
            ab = first(w, t0, lambda s: s.get("rollout", {}).get("abort"))
            row["abort_s"] = round(ab - t0, 1) if ab else None
            row["abort_after_ready_s"] = round(ab - ready, 1) if ab and ready else None
            if ab:
                back = first(w, ab, lambda s: pods(s, "v2") == 0 and serving(s, "v1") >= 2)
                row["v1_only_after_ready_s"] = round(back - ready, 1) if back and ready else None
            last = w[-1].get("analysis", [])
            row["analysis"] = [{"phase": a["phase"], "values": a["values"], "message": a.get("message"),
                                "errors": a.get("errors", [])} for a in last]
        full = first(w, t0, lambda s: serving(s, "v2") >= 2 and pods(s, "v1") == 0)
        row["all_v2_s"] = round(full - t0, 1) if full else None
        span_w = [s for s in w if s["t"] >= t0]
        row["min_serving"] = min((serving(s, "v1") + serving(s, "v2")) for s in span_w) if span_w else None
    if os.path.exists(wpath):
        w = [json.loads(l) for l in open(wpath)]
        row["restarts"] = max((sum(v.get("restarts", 0) for v in s.get("versions", {}).values()) for s in w), default=None)
    ppath = f"{d}/{meta['name']}.pods.json"
    if os.path.exists(ppath):
        try:
            row["pods"] = json.load(open(ppath))
        except ValueError:
            row["pods"] = None
    return row


def pods_lines(r):
    """Per pod: requests and fraction with TTFT <= T_b over the replay; per
    minute (offset from the replay start: requests/good) for v2 pods."""
    out = []
    for p in r.get("pods") or []:
        n = sum(m[1] for m in p["minutes"])
        g = sum(m[2] for m in p["minutes"])
        line = f"  - {p['pod']} ({p['version']}): {n:.0f} requests, {g / n * 100:.0f} % at or under T_b" if n else \
            f"  - {p['pod']} ({p['version']}): no requests"
        if p["version"] == "v2" and n:
            line += "; per minute " + " ".join(f"+{m[0]}s {m[1]:.0f}/{m[2]:.0f}" for m in p["minutes"] if m[1])
        out.append(line)
    return out


def main():
    jobs = {}
    for d in sys.argv[1:]:
        rows = []
        for f in sorted(glob.glob(f"{d}/*.meta.json")):
            rows.append(rep_row(d, json.load(open(f))))
        arms = sorted({r["arm"] for r in rows} - {"baseline"})
        if rows:
            jobs[os.path.basename(os.path.normpath(d)) + " (" + (", ".join(arms) or "baseline only") + ")"] = (d, rows)

    fmt = lambda x, n=0: "n/a" if x is None else (f"{x * 100:.{n}f} %" if isinstance(x, float) else str(x))
    print("# Canary rollback report\n")
    for job, (d, rows) in sorted(jobs.items()):
        c = json.load(open(f"{d}/calib-conv.json")) if os.path.exists(f"{d}/calib-conv.json") else {}
        tb = json.load(open(f"{d}/tb.json")) if os.path.exists(f"{d}/tb.json") else {}
        print(f"## {job}\n")
        print(f"T = {c.get('T')} s, P = {c.get('P')} s, C = {c.get('C')} req/s, replay mean {c.get('rate')} req/s; "
              f"analysis bucket T_b = {tb.get('T_b')} s (le=\"{tb.get('le')}\")\n")
        print("| rep | arm | requests | failed | budget burned (replay) | span from | budget burned (span) | canary Ready | abort | abort after Ready | v1 only after Ready | all v2 | min pods serving | restarts |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in rows:
            print(f"| {r['name']} | {r['arm']} | {r['requests']} | {r['failed']} | {fmt(r['budget'])} | +{r['span_from_s']} s | "
                  f"{fmt(r['budget_span'])} | {r.get('canary_ready_s', 'n/a')} s | {r.get('abort_s', 'n/a')} s | "
                  f"{r.get('abort_after_ready_s', 'n/a')} s | {r.get('v1_only_after_ready_s', 'n/a')} s | {r.get('all_v2_s', 'n/a')} s | "
                  f"{r.get('min_serving', 'n/a')} | {r.get('restarts', 'n/a')} |")
        for r in rows:
            pl = pods_lines(r)
            if pl:
                print(f"\n- {r['name']} per pod:\n" + "\n".join(pl))
        for r in rows:
            for a in r.get("analysis", []):
                print(f"\n- {r['name']} analysis {a['phase']}: {', '.join(str(v) for v in a['values'])}"
                      + (f" ({a['message']}; {'; '.join(a['errors'])})" if a.get("message") or a.get("errors") else ""))
        print()

    # Hypotheses
    def arm_rows(arm):
        return [(d, r) for _, (d, rows) in jobs.items() for r in rows if r["arm"] == arm]

    def excess(rows, arm):
        a = [r["budget_span"] for r in rows if r["arm"] == arm and r["budget_span"] is not None]
        b = [r["budget_span"] for r in rows if r["arm"] == "baseline" and r["budget_span"] is not None]
        return (st.median(a) - st.median(b), st.median(a), st.median(b)) if a and b else None

    print("## Hypotheses\n")
    arm_reps = [r for _, (d, rows) in jobs.items() for r in rows if r["arm"] != "baseline"]
    if arm_reps:
        bad = [r for r in arm_reps if r["failed"]]
        print(f"- H1 ({'holds' if not bad else 'refuted'}): failed requests per rep: "
              + ", ".join(f"{r['arm']} {r['name']} {r['failed']}" for r in arm_reps))
    bc = [r for _, r in arm_rows("bad-canary")]
    if bc:
        ok = all(r.get("abort_after_ready_s") is not None and r["abort_after_ready_s"] <= 300
                 and r.get("v1_only_after_ready_s") is not None and r["v1_only_after_ready_s"] <= 420 for r in bc)
        print(f"- H2 ({'holds' if ok else 'refuted'}): " + "; ".join(
            f"{r['name']} abort {r.get('abort_after_ready_s')} s and v1 only {r.get('v1_only_after_ready_s')} s after canary Ready"
            for r in bc))
    h3 = []
    for job, (d, rows) in sorted(jobs.items()):
        eb, er = excess(rows, "bad-canary"), excess(rows, "bad-rolling")
        if eb and er:
            h3.append((job, er[0] > 0 and eb[0] <= 0.5 * er[0], eb, er))
    if h3:
        print(f"- H3 ({'holds' if all(ok for _, ok, _, _ in h3) else 'refuted'}; same job only): " + "; ".join(
            f"{job}: bad-canary {eb[0] * 100:.0f} points ({eb[1] * 100:.0f} % vs baseline {eb[2] * 100:.0f} %), "
            f"bad-rolling {er[0] * 100:.0f} points ({er[1] * 100:.0f} % vs baseline {er[2] * 100:.0f} %), "
            f"{'holds' if ok else 'refuted'}" for job, ok, eb, er in h3))
    else:
        print("- H3 (not evaluated): no job holds both bad-canary and bad-rolling")
    gc = arm_rows("good-canary")
    if gc:
        res = []
        for d, r in gc:
            base = [x["budget_span"] for x in jobs_rows(jobs, d) if x["arm"] == "baseline"]
            b = st.median(base) if base else None
            promoted = r.get("all_v2_s") is not None and not any(a["phase"] == "Failed" for a in r.get("analysis", []))
            within = b is not None and r["budget_span"] is not None and r["budget_span"] <= 1.5 * b
            res.append((r, promoted, within, b))
        ok = all(p and w for _, p, w, _ in res)
        print(f"- H4 ({'holds' if ok else 'refuted'}): " + "; ".join(
            f"{r['name']} promoted {p}, span budget {fmt(r['budget_span'])} vs 1.5 x baseline {fmt(1.5 * b if b is not None else None)}"
            for r, p, _, b in res))


def jobs_rows(jobs, d):
    for _, (dd, rows) in jobs.items():
        if dd == d:
            return rows
    return []


if __name__ == "__main__":
    main()
