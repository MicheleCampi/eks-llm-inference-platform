#!/usr/bin/env python3
"""Report of the FinOps guardrail experiment (README.md): per job and rep,
per tenant, responses by class, error budget burned against the tenant's own
SLO, good tokens; EUR per million good tokens of the window; then H1-H3
against their written thresholds, each comparison inside one job.
Usage: report.py RESULTS_DIR [RESULTS_DIR ...]   (one directory per job)
       report.py --one REP.jsonl REP.meta.json   (one line, after a rep)"""
import glob
import json
import os
import statistics as st
import sys

# Step 7 reference price (README "Cost"): 4 vCPU of replicas, on demand,
# eu-west-1, read 17/11; not a price paid.
USD_PER_H = 2 * 0.1067
EUR_PER_USD = float(os.environ.get("EUR_PER_USD", "0.86"))
BUDGET = {"premium": 0.01, "batch": 0.05}


def load(path):
    reqs, summary = [], None
    for line in open(path):
        if line.startswith('{"req"'):
            reqs.append(json.loads(line)["req"])
        elif line.startswith('{"summary"'):
            summary = json.loads(line)["summary"]
    return reqs, summary


def klass(r):
    c = r.get("code")
    if c == 200 and r.get("ttft") is not None:
        return "200"
    if c == 200:
        return "200 no first chunk"
    if c == 429:
        return "429"
    if c == 0:
        return "timeout" if "timed out" in (r.get("error") or "") else "connection error"
    return f"{c}"


def good(r, tenant, T, P, x):
    if klass(r) != "200":
        return False
    t, p = (T, P) if tenant == "premium" else (x * T, 2 * P)
    return r["ttft"] <= t and (r.get("tpot") is None or r["tpot"] <= p)


def rep_row(jsonl, meta):
    reqs, summary = load(jsonl)
    T, P, x = meta["T"], meta["P"], meta["batch_ttft_x"]
    row = {"name": meta["name"], "arm": meta["arm"], "wall_s": (summary or {}).get("wall_s"), "tenants": {}}
    for tenant in ("premium", "batch"):
        rs = [r for r in reqs if r.get("tenant") == tenant]
        g = [r for r in rs if good(r, tenant, T, P, x)]
        classes = {}
        for r in rs:
            classes[klass(r)] = classes.get(klass(r), 0) + 1
        q = [float(r["queue_ms"]) for r in rs if r.get("queue_ms") not in (None, "")]
        ttft = sorted(r["ttft"] for r in rs if klass(r) == "200")
        row["tenants"][tenant] = {
            "requests": len(rs), "good": len(g), "classes": classes,
            "budget": ((len(rs) - len(g)) / len(rs)) / BUDGET[tenant] if rs else None,
            "good_tokens": sum(r.get("completion_tokens") or 0 for r in g),
            "ttft_p95": ttft[min(len(ttft) - 1, int(0.95 * len(ttft)))] if ttft else None,
            "queue_ms_p95": sorted(q)[min(len(q) - 1, int(0.95 * len(q)))] if q else None,
        }
    window_h = (row["wall_s"] or 1200) / 3600
    eur = USD_PER_H * EUR_PER_USD * window_h
    gt = sum(t["good_tokens"] for t in row["tenants"].values())
    row["eur_window"] = eur
    row["eur_per_mgood"] = eur / gt * 1e6 if gt else None
    return row


def fmt(x, pct=False):
    if x is None:
        return "n/a"
    return f"{x * 100:.0f} %" if pct else (f"{x:.2f}" if isinstance(x, float) else str(x))


def main():
    if sys.argv[1] == "--one":
        r = rep_row(sys.argv[2], json.load(open(sys.argv[3])))
        print(json.dumps({"rep": r["name"], "arm": r["arm"], "eur_per_mgood": r["eur_per_mgood"],
                          **{t: {"budget": v["budget"], "classes": v["classes"]} for t, v in r["tenants"].items()}}))
        return
    jobs = {}
    for d in sys.argv[1:]:
        rows = [rep_row(f[:-len(".meta.json")] + ".jsonl", json.load(open(f)))
                for f in sorted(glob.glob(f"{d}/*.meta.json"))]
        if rows:
            jobs[os.path.basename(os.path.normpath(d))] = rows
    print("# FinOps guardrail report\n")
    print(f"Reference price {USD_PER_H:.4f} USD/h x {EUR_PER_USD} EUR/USD; budgets: premium 1 %, batch 5 %.\n")
    for job, rows in sorted(jobs.items()):
        print(f"## {job}\n")
        print("| rep | arm | tenant | requests | good | responses | budget burned | TTFT p95 (200s) | queue p95 ms | EUR per M good tokens (window) |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for r in rows:
            for t, v in r["tenants"].items():
                cl = ", ".join(f"{k} {n}" for k, n in sorted(v["classes"].items()))
                print(f"| {r['name']} | {r['arm']} | {t} | {v['requests']} | {v['good']} | {cl} | {fmt(v['budget'], True)} | "
                      f"{fmt(v['ttft_p95'])} | {fmt(v['queue_ms_p95'])} | {fmt(r['eur_per_mgood'])} |")
        print()
    print("## Hypotheses\n")
    h1, h2, h3 = [], [], []
    for job, rows in sorted(jobs.items()):
        def med(arm, f):
            xs = [f(r) for r in rows if r["arm"] == arm and f(r) is not None]
            return st.median(xs) if xs else None
        pn = med("nopolicy", lambda r: r["tenants"]["premium"]["budget"])
        pg = med("guardrail", lambda r: r["tenants"]["premium"]["budget"])
        worst = max((r["tenants"]["premium"]["budget"] or 0 for r in rows if r["arm"] == "guardrail"), default=None)
        if pn is not None and pg is not None:
            ok = pg <= 0.5 * pn and worst <= 1.0
            h1.append((ok, f"{job}: premium budget {fmt(pg, True)} with guardrail vs {fmt(pn, True)} without (limit half, and "
                           f"<= 100 % in every rep: worst {fmt(worst, True)})"))
        en = med("nopolicy", lambda r: r["eur_per_mgood"])
        eg = med("guardrail", lambda r: r["eur_per_mgood"])
        if en is not None and eg is not None:
            h2.append((eg <= 1.1 * en, f"{job}: {eg:.2f} EUR per M good tokens with guardrail vs {en:.2f} without (limit 1.1 x)"))
        for r in rows:
            if r["arm"] != "guardrail":
                continue
            prem_bad = sum(n for k, n in r["tenants"]["premium"]["classes"].items() if k != "200")
            batch_other = sum(n for k, n in r["tenants"]["batch"]["classes"].items() if k not in ("200", "429"))
            h3.append((prem_bad == 0 and batch_other == 0,
                       f"{job} {r['name']}: premium non-200 {prem_bad}, batch non-200 other than 429 {batch_other}"))
    for name, rs in (("H1", h1), ("H2", h2), ("H3", h3)):
        if rs:
            print(f"- {name} ({'holds' if all(ok for ok, _ in rs) else 'refuted'}): " + "; ".join(t for _, t in rs))
        else:
            print(f"- {name} (not evaluated): no data")


if __name__ == "__main__":
    main()
