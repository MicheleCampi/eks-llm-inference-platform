"""Summary of one or more client result files: failures, and failures per
1 ms bin of the idle gap, next to the Envoy access-log lines with a flag."""
import collections
import json
import pathlib
import sys

for path in map(pathlib.Path, sys.argv[1:]):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    timed = rows[1:]  # row 0 is the warm-up request
    bad = [r for r in timed if r["code"] != 200]
    env = path.with_suffix("").with_suffix(".envoy.log")
    lines = [json.loads(x) for x in env.read_text().splitlines()] if env.exists() else []
    flagged = [x for x in lines if x.get("flags", "-") != "-"]
    retried = [x for x in lines if str(x.get("attempts", "1")) != "1"]
    print(f"{path.stem}: {len(timed) - len(bad)}/{len(timed)} ok, {len(bad)} failed; "
          f"envoy lines {len(lines)}, with a flag {len(flagged)}, with more than 1 attempt {len(retried)}")
    for r in bad:
        print(f"  failed i={r['i']} gap={r['gap']} code={r['code']} e2e={r['e2e']} {r['body'][:90]}")
    for x in flagged:
        print(f"  envoy {x.get('flags')} {x.get('details')} {x.get('duration_ms')} ms attempts={x.get('attempts')}")
    for x in retried:
        print(f"  envoy retried: status {x.get('status')} attempts={x.get('attempts')} {x.get('duration_ms')} ms")
    if bad:
        hist = collections.Counter(int(r["gap"] * 1000) for r in bad)
        print("  failures per 1 ms gap bin:", dict(sorted(hist.items())))
