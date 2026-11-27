#!/usr/bin/env python3
"""Report of the trace replay (README.md): per trace and arm, SLO, error
budget, where the budget was burned, cost per million tokens and per million
good tokens; then H1-H3 checked against their written thresholds.
Usage: report.py RESULTS_DIR"""
import collections
import glob
import json
import os
import statistics as st
import sys

# README "Cost": reference price, not a price paid. 2 x m7i-flex.large-equivalent
# vCPU pairs (4 vCPU of replicas), on demand, eu-west-1, read 17/11.
USD_PER_H = 2 * 0.1067
EUR_PER_USD = float(os.environ.get("EUR_PER_USD", "0.86"))


def load(path):
    reqs, summary = [], None
    for line in open(path):
        d = json.loads(line)
        if "req" in d:
            reqs.append(d["req"])
        elif "summary" in d:
            summary = d["summary"]
    return reqs, summary


def peak_share(reqs):
    """Share of bad requests that fall in the busiest 20 % of minutes (by
    offered requests)."""
    per_min = collections.Counter(int(r["offset"] // 60) for r in reqs)
    n = max(1, round(0.2 * len(per_min)))
    peak = {m for m, _ in per_min.most_common(n)}
    bad = [r for r in reqs if not r["good"]]
    return (sum(1 for r in bad if int(r["offset"] // 60) in peak) / len(bad)) if bad else None


def main():
    d = sys.argv[1]
    calib = {json.load(open(f))["trace"]: json.load(open(f)) for f in glob.glob(f"{d}/calib-*.json")
             if not f.endswith(".jsonl")}
    rows = collections.defaultdict(list)
    for f in sorted(glob.glob(f"{d}/*-*-*.jsonl")):
        name = os.path.basename(f)[:-6]
        parts = name.split("-")
        if parts[0] == "calib" or len(parts) != 3:
            continue
        t, arm, rep = parts
        reqs, s = load(f)
        if s is None:
            continue
        hours = s["meta"].get("replay_s", s["meta"].get("window_s", s["wall_s"])) / 3600
        eur = USD_PER_H * hours * EUR_PER_USD
        rows[(t, arm)].append({
            "rep": rep, "s": s, "peak_share": peak_share(reqs),
            "eur_mtok": eur / s["completion_tokens"] * 1e6 if s["completion_tokens"] else None,
            "eur_mtok_good": eur / s["good_completion_tokens"] * 1e6 if s["good_completion_tokens"] else None,
        })

    print("# Trace replay report\n")
    print(f"Reference price {USD_PER_H:.4f} USD/h for 4 vCPU of replicas, {EUR_PER_USD} EUR per USD (assumed, not read).\n")
    for t, c in sorted(calib.items()):
        print(f"- {t}: T = {c['T']} s, P = {c['P']} s, C = {c['C']} req/s, replay mean {c['rate']} req/s")
    print("\n| trace | arm | rep | requests | failed | good | budget burned | bad in busiest 20 % of minutes | TTFT p50 / p95 s | TPOT p95 s | EUR / M tokens | EUR / M good tokens | dispatch lag p99 s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    fmt = lambda x, n=3: "n/a" if x is None else f"{x:.{n}f}"
    for (t, arm), rs in sorted(rows.items()):
        for r in sorted(rs, key=lambda r: r["rep"]):
            s = r["s"]
            print(f"| {t} | {arm} | {r['rep']} | {s['requests']} | {s['failed']} | {s['good_fraction']:.4f} | "
                  f"{s['budget_burned'] * 100:.0f} % | {fmt(r['peak_share'], 2)} | {fmt(s['ttft_p50'])} / {fmt(s['ttft_p95'])} | "
                  f"{fmt(s['tpot_p95'])} | {fmt(r['eur_mtok'], 2)} | {fmt(r['eur_mtok_good'], 2)} | {fmt(s['dispatch_lag_p99'])} |")

    med = lambda rs, key: st.median([r[key] if key in r else r["s"][key] for r in rs]) if rs else None
    print("\n## Hypotheses (medians over repetitions)\n")
    traces = sorted({t for t, _ in rows})
    h1 = []
    for t in traces:
        sv = rows.get((t, "service"), [])
        if sv:
            burned, share = med(sv, "budget_burned"), st.median([r["peak_share"] or 0 for r in sv])
            h1.append((t, burned > 1 and share > 0.5, burned, share))
    if h1:
        verdict = "holds" if any(x[1] for x in h1) else "refuted"
        print(f"- H1 ({verdict}): " + "; ".join(f"{t} burned {b * 100:.0f} %, {s:.2f} of bad in peak minutes" for t, _, b, s in h1))
    h2, h3 = [], []
    for t in traces:
        sv, rt = rows.get((t, "service"), []), rows.get((t, "router"), [])
        if sv and rt:
            bs, br = med(sv, "budget_burned"), med(rt, "budget_burned")
            h2.append((t, bs > 0 and br <= 0.75 * bs, bs, br))
            cs, cr = med(sv, "eur_mtok"), med(rt, "eur_mtok")
            gs, gr = med(sv, "eur_mtok_good"), med(rt, "eur_mtok_good")
            h3.append((t, abs(cr - cs) / cs < 0.05 and gr < gs, cs, cr, gs, gr))
    if h2:
        verdict = ("not testable: the service arm burned no budget" if any(x[2] == 0 for x in h2)
                   else "holds" if all(x[1] for x in h2) else "refuted")
        print(f"- H2 ({verdict}): " + "; ".join(f"{t} service {bs * 100:.0f} %, router {br * 100:.0f} %" for t, _, bs, br in h2))
    if h3:
        verdict = "holds" if all(x[1] for x in h3) else "refuted"
        print(f"- H3 ({verdict}): " + "; ".join(
            f"{t} EUR/M tokens {cs:.2f} vs {cr:.2f}, EUR/M good tokens {gs:.2f} vs {gr:.2f}" for t, _, cs, cr, gs, gr in h3))


if __name__ == "__main__":
    main()
