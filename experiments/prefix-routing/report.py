#!/usr/bin/env python3
"""Table of every arm summary in the given loadgen outputs (*.jsonl):
medians over repetitions, hit rate per repetition, requests per replica.
Used by run.sh (kind) and eks/run.sh (EKS)."""
import json, sys, statistics as st
rows = {}
for f in sys.argv[1:]:
    b = f.split("/")[-1].split("-")[0]
    for line in open(f):
        if '"summary"' in line:
            s = json.loads(line)["summary"]
            rows.setdefault((b, s["arm"]), []).append(s)
med = lambda xs: st.median(xs) if xs else float("nan")
print("| backend | arm | runs | requests ok/total | prefix hit rate | TTFT p50 s | TTFT p90 s | TTFT mean s | wall s | requests per replica |")
print("|---|---|---|---|---|---|---|---|---|---|")
for (b, arm), ss in sorted(rows.items(), key=lambda kv: (kv[0][0], ["service", "random", "prefix", "legacy", "ea"].index(kv[0][1]) if kv[0][1] in ("service", "random", "prefix", "legacy", "ea") else 9)):
    ok = sum(s["ok"] for s in ss); tot = sum(s["requests"] for s in ss)
    hr = ", ".join(f'{s["hit_rate"]:.3f}' for s in ss)
    spread = " / ".join(",".join(str(int(p["success"])) for p in s["per_pod"].values()) for s in ss)
    print(f'| {b} | {arm} | {len(ss)} | {ok}/{tot} | {hr} | {med([s["ttft_p50"] for s in ss]):.3f} | {med([s["ttft_p90"] for s in ss]):.3f} | {med([s["ttft_mean"] for s in ss]):.3f} | {med([s["wall_s"] for s in ss]):.1f} | {spread} |')
for b in sorted({b for b, _ in rows}):
    s0 = next(ss[0] for (bb, _), ss in rows.items() if bb == b)
    print(f'\n{b}: {s0["replicas"]} replicas, {s0["requests"]} requests per arm at concurrency {s0["concurrency"]}; {s0["groups"]} groups (shared prefixes) of {s0["prefix_words"]} words, {s0["question_words"]}-word unique question, {s0["max_tokens"]} output tokens, seed {s0["seed"]}; capacity {s0["capacity_tokens_per_replica"]} tokens per replica.')
