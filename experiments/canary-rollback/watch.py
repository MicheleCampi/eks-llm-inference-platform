#!/usr/bin/env python3
"""Record the rollout's state every 2 s, one JSON line per sample, until the
duration ends: pods by version (Ready and not terminating = serving, since
a terminating pod has left the Service endpoints), the Rollout's phase,
abort flag and step, and the AnalysisRun phases with their measurements.
  watch.py NAMESPACE KIND DURATION_S OUT      KIND = rollout | deployment
Runs on the runner with kubectl; standard library only."""
import json
import subprocess
import sys
import time

ns, kind, duration, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]


def get(*args):
    r = subprocess.run(["kubectl", "-n", ns, "--request-timeout=10s", "get", *args, "-o", "json"],
                       capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout else None


def sample():
    s = {"t": round(time.time(), 2)}
    pods = get("pods", "-l", "app=model") or {"items": []}
    by = {}
    for p in pods["items"]:
        v = p["metadata"]["labels"].get("version", "?")
        ready = any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))
        term = "deletionTimestamp" in p["metadata"]
        d = by.setdefault(v, {"pods": 0, "serving": 0, "terminating": 0})
        d["pods"] += 1
        d["serving"] += ready and not term
        d["terminating"] += term
    s["versions"] = by
    if kind == "rollout":
        ro = get("rollout", "model")
        if ro:
            st = ro.get("status", {})
            s["rollout"] = {"phase": st.get("phase"), "abort": st.get("abort", False),
                            "step": st.get("currentStepIndex"), "message": st.get("message")}
        runs = get("analysisruns") or {"items": []}
        s["analysis"] = [{"name": a["metadata"]["name"], "phase": a.get("status", {}).get("phase"),
                          "values": [m.get("value") for mr in a.get("status", {}).get("metricResults", [])
                                     for m in mr.get("measurements", [])],
                          "statuses": [m.get("phase") for mr in a.get("status", {}).get("metricResults", [])
                                       for m in mr.get("measurements", [])],
                          "message": a.get("status", {}).get("message"),
                          "errors": sorted({m["message"] for mr in a.get("status", {}).get("metricResults", [])
                                            for m in mr.get("measurements", []) if m.get("message")})}
                         for a in runs["items"]]
    else:
        dep = get("deployment", "model")
        if dep:
            st = dep.get("status", {})
            s["deployment"] = {"updated": st.get("updatedReplicas"), "ready": st.get("readyReplicas"),
                               "observed": st.get("observedGeneration"), "generation": dep["metadata"]["generation"]}
    return s


end = time.time() + duration
with open(out, "a") as f:
    while time.time() < end:
        f.write(json.dumps(sample()) + "\n")
        f.flush()
        time.sleep(2)
