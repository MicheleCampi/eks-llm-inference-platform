#!/usr/bin/env python3
"""Report of the noisy-neighbor experiment (README.md): per job and rep, per
tenant, responses by class, error budget burned against the tenant's own
SLO, good tokens and EUR per million good tokens (the rules and code of
../finops-guardrail/report.py, unchanged); the guardrail checks; then H1-H4
against their written thresholds, each comparison inside one job.
Usage: report.py RESULTS_DIR [RESULTS_DIR ...]   (one directory per job)
       report.py --one REP.jsonl REP.meta.json   (one line, after a rep)"""
import glob
import importlib.util
import json
import os
import statistics as st
import sys

_spec = importlib.util.spec_from_file_location(
    "finops_report", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "finops-guardrail", "report.py"))
fr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fr)
fmt = fr.fmt


def checks(d):
    p = os.path.join(d, "checks.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def main():
    if sys.argv[1] == "--one":
        r = fr.rep_row(sys.argv[2], json.load(open(sys.argv[3])))
        print(json.dumps({"rep": r["name"], "arm": r["arm"], "eur_per_mgood": r["eur_per_mgood"],
                          **{t: {"budget": v["budget"], "classes": v["classes"]} for t, v in r["tenants"].items()}}))
        return
    jobs = {}
    for d in sys.argv[1:]:
        rows = [fr.rep_row(f[:-len(".meta.json")] + ".jsonl", json.load(open(f)))
                for f in sorted(glob.glob(f"{d}/*.meta.json"))]
        jobs[os.path.basename(os.path.normpath(d))] = (rows, checks(d))
    print("# Noisy neighbor report\n")
    print(f"Reference price {fr.USD_PER_H:.4f} USD/h x {fr.EUR_PER_USD} EUR/USD; budgets: premium 1 %, batch 5 %.\n")
    for job, (rows, cks) in sorted(jobs.items()):
        print(f"## {job}\n")
        if rows:
            print("| rep | arm | tenant | requests | good | responses | budget burned | TTFT p95 (200s) | EUR per M good tokens (window) |")
            print("|---|---|---|---|---|---|---|---|---|")
            for r in rows:
                for t, v in r["tenants"].items():
                    cl = ", ".join(f"{k} {n}" for k, n in sorted(v["classes"].items()))
                    print(f"| {r['name']} | {r['arm']} | {t} | {v['requests']} | {v['good']} | {cl} | {fmt(v['budget'], True)} | "
                          f"{fmt(v['ttft_p95'])} | {fmt(r['eur_per_mgood'])} |")
            print()
        if cks:
            print("| check | result | detail |")
            print("|---|---|---|")
            for c in cks:
                print(f"| {c['check']} | {'pass' if c['ok'] else 'FAIL'} | {c['detail'].replace('|', '/')[:400]} |")
            print()
    print("## Hypotheses\n")
    h = {"H1": [], "H2": [], "H3": [], "H4": []}
    for job, (rows, cks) in sorted(jobs.items()):
        def med(arm, f):
            xs = [f(r) for r in rows if r["arm"] == arm and f(r) is not None]
            return st.median(xs) if xs else None
        ps = med("shared", lambda r: r["tenants"]["premium"]["budget"])
        pi = med("isolated", lambda r: r["tenants"]["premium"]["budget"])
        worst = max((r["tenants"]["premium"]["budget"] or 0 for r in rows if r["arm"] == "isolated"), default=None)
        if ps is not None and pi is not None:
            h["H1"].append((pi <= 0.5 * ps and worst <= 1.0,
                            f"{job}: premium budget {fmt(pi, True)} isolated vs {fmt(ps, True)} shared (limit half, and "
                            f"<= 100 % in every isolated rep: worst {fmt(worst, True)})"))
        es = med("shared", lambda r: r["eur_per_mgood"])
        ei = med("isolated", lambda r: r["eur_per_mgood"])
        if es is not None and ei is not None:
            h["H2"].append((ei <= 1.1 * es, f"{job}: {ei:.2f} EUR per M good tokens isolated vs {es:.2f} shared (limit 1.1 x)"))
        h3 = [c for c in cks if c["check"].startswith("H3")]
        if h3:
            h["H3"].append((len(h3) == 4 and all(c["ok"] for c in h3),
                            f"{job}: " + ", ".join(f"{c['check']} {'pass' if c['ok'] else 'FAIL'}" for c in h3)))
        h4 = [c for c in cks if c["check"].startswith("H4")]
        if h4:
            h["H4"].append((all(c["ok"] for c in h4), f"{job}: " + "; ".join(c["detail"] for c in h4)))
    for name, rs in h.items():
        if rs:
            print(f"- {name} ({'holds' if all(ok for ok, _ in rs) else 'refuted'}): " + "; ".join(t for _, t in rs))
        else:
            print(f"- {name} (not evaluated): no data")


if __name__ == "__main__":
    main()
