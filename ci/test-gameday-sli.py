"""Unit test of scripts/gameday-sli.py on ci/fixtures/gameday/probe.log:
8 requests in the old format, 2 failed (no answer, 503), 1 slow (19.2 s), 1
non-JSON line; then 2 in the format with the retry: one answered on its retry
after a refused first try, one on the first try.
Usage: python3 -I ci/test-gameday-sli.py"""
import importlib.util, math, pathlib, sys
sys.dont_write_bytecode = True  # no __pycache__ in the work tree
root = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sli", root / "scripts/gameday-sli.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lines = open(root / "ci/fixtures/gameday/probe.log").read().splitlines()

r = m.sli(lines)
assert (r["requests"], r["failed"], r["slow_or_failed"], r["skipped_lines"]) == (10, 2, 3, 1), r
assert math.isclose(r["availability"], 8 / 10) and math.isclose(r["latency"], 7 / 10), r
# The retried request counts as answered for the user; the first try did not.
assert r["retried"] == 1 and math.isclose(r["first_try_availability"], 1 / 2), r
# 30 days at one probe every 2 s = 1,296,000 requests; 0.5 % = 6,480 may fail.
assert math.isclose(r["avail_budget_used_pct"], 100 * 2 / 6480), r
# 5 % = 64,800 may be slow or fail.
assert math.isclose(r["latency_budget_used_pct"], 100 * 3 / 64800), r
# The window keeps only lines inside [from, to].
w = m.sli(lines, "2026-11-20T20:00:08Z", "2026-11-20T20:00:14Z")
assert (w["requests"], w["failed"]) == (4, 1), w
# Old-format lines only: no first-try figure, not a made-up 100 %.
assert w["first_try_availability"] is None, w
# An empty window is an error, never a met objective.
try:
    m.sli(lines, "2026-11-21T00:00:00Z")
    raise AssertionError("empty window accepted")
except SystemExit as e:
    assert "no probe lines" in str(e)
print("gameday-sli: 5 cases pass")
