#!/usr/bin/env python3
"""SLIs of a game day scenario from the probe log (tests/gameday/probe.yaml).

Usage: gameday-sli.py LOG [--from UTC] [--to UTC] [--interval 2]
Reads one JSON object per line ({"t","code","s"}); other lines are skipped
and counted. Prints the availability SLI (HTTP 200), the latency SLI
(200 within 8 s) and the share of the 30-day error budget each consumed,
against the SLO of docs/gameday/README.md section 1: availability 99.5 %,
latency 95 %. The month's request count is taken as one probe every
--interval seconds for 30 days, so the budget share does not depend on the
length of the window.
"""
import argparse, json, sys

AVAIL_OBJ, LAT_OBJ, LAT_S = 0.995, 0.95, 8.0
MONTH_S = 30 * 86400


def sli(lines, start=None, end=None, interval=2.0):
    total = ok = fast = skipped = 0
    first = last = None
    for line in lines:
        try:
            r = json.loads(line)
            t, code, s = r["t"], int(r["code"]), float(r["s"])
        except (ValueError, KeyError, TypeError):
            skipped += 1
            continue
        if (start and t < start) or (end and t > end):
            continue
        total += 1
        first = first or t
        last = t
        if code == 200:
            ok += 1
            if s <= LAT_S:
                fast += 1
    if total == 0:
        raise SystemExit("no probe lines in the window")
    month = MONTH_S / interval
    return {
        "window": f"{first} .. {last}",
        "requests": total,
        "failed": total - ok,
        "slow_or_failed": total - fast,
        "availability": ok / total,
        "latency": fast / total,
        "avail_budget_used_pct": 100 * (total - ok) / ((1 - AVAIL_OBJ) * month),
        "latency_budget_used_pct": 100 * (total - fast) / ((1 - LAT_OBJ) * month),
        "skipped_lines": skipped,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("log")
    p.add_argument("--from", dest="start")
    p.add_argument("--to", dest="end")
    p.add_argument("--interval", type=float, default=2.0)
    a = p.parse_args()
    with open(a.log) as f:
        r = sli(f, a.start, a.end, a.interval)
    print(f"window             {r['window']}")
    print(f"requests           {r['requests']} (failed {r['failed']}, slow or failed {r['slow_or_failed']}, skipped lines {r['skipped_lines']})")
    print(f"availability SLI   {100 * r['availability']:.3f} % (objective {100 * AVAIL_OBJ} %) {'MET' if r['availability'] >= AVAIL_OBJ else 'MISSED'}")
    print(f"latency SLI        {100 * r['latency']:.3f} % within {LAT_S:g} s (objective {100 * LAT_OBJ:g} %) {'MET' if r['latency'] >= LAT_OBJ else 'MISSED'}")
    print(f"30-day budget used availability {r['avail_budget_used_pct']:.3f} %, latency {r['latency_budget_used_pct']:.3f} %")


if __name__ == "__main__":
    sys.exit(main())
