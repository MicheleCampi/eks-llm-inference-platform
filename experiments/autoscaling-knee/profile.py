#!/usr/bin/env python3
"""Step load from the step 7 conv window (README "Load"): each segment of the
window keeps its own arrivals, thinned with the step 7 seed to the segment's
mean rate; times and lengths are the trace's.
Usage: profile.py WINDOW.json OUT.json"""
import json
import random
import sys

SEED = 20261126
SEGMENTS = [(0, 300, 0.3), (300, 900, 1.0), (900, 1200, 0.3)]  # fixed in README.md


def main():
    w = json.load(open(sys.argv[1]))
    assert w["meta"]["window_s"] == 1200, w["meta"]
    out, seg_meta = [], []
    for k, (a, b, rate) in enumerate(SEGMENTS):
        rs = [r for r in w["requests"] if a <= r[0] < b]
        p = rate * (b - a) / len(rs)
        assert p <= 1, f"segment {a}-{b}: the window has fewer arrivals than {rate} req/s"
        rnd = random.Random(SEED + k)
        kept = [r for r in rs if rnd.random() < p]
        out += kept
        seg_meta.append({"from_s": a, "to_s": b, "target_rps": rate, "requests": len(kept),
                         "mean_rps": round(len(kept) / (b - a), 4)})
    meta = dict(w["meta"], profile="step", segments=seg_meta, seed=SEED, replay_s=1200,
                requests=len(out), mean_rps=round(len(out) / 1200, 4))
    json.dump({"meta": meta, "requests": out}, open(sys.argv[2], "w"))
    print(json.dumps({k: meta[k] for k in ("requests", "mean_rps", "segments")}))


if __name__ == "__main__":
    main()
