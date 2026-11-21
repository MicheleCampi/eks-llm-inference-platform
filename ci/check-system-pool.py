"""Every platform workload runs on pool system and tolerates its taint.

Pool system is the EKS managed node group (On-Demand, outside Karpenter),
tainted CriticalAddonsOnly=true:NoSchedule (modules/eks/main.tf) so only the
platform's controllers run there (game day #1, S3 postmortem). A controller
that misses the toleration does not fail: it moves to a Karpenter Spot node,
where a consolidation or an interruption can drain the components that
recover the cluster. This check makes that a CI failure instead.

Each pod template in the rendered files (Deployment, StatefulSet, Job,
CronJob, Pod) needs nodeSelector platform.michelecampi.dev/pool=system and a
toleration of CriticalAddonsOnly with effect NoSchedule (or no effect).
DaemonSets run on every node by design and are listed, not checked. The
metrics-server add-on configuration (JSON) is checked the same way.

Usage: check-system-pool.py METRICS_SERVER_JSON RENDERED_MANIFEST...
"""
import json
import sys

import yaml

POOL_LABEL = "platform.michelecampi.dev/pool"
TAINT_KEY = "CriticalAddonsOnly"


def tolerates(tolerations):
    for t in tolerations or []:
        effect_ok = t.get("effect") in (None, "", "NoSchedule")
        op = t.get("operator", "Equal")
        if t.get("key") == TAINT_KEY and effect_ok and (op == "Exists" or str(t.get("value")) == "true"):
            return True
    return False


def problems(spec):
    out = []
    if (spec.get("nodeSelector") or {}).get(POOL_LABEL) != "system":
        out.append(f"nodeSelector {POOL_LABEL}=system missing")
    if not tolerates(spec.get("tolerations")):
        out.append(f"no {TAINT_KEY} toleration")
    return out


def pod_spec(doc):
    kind, spec = doc.get("kind"), doc.get("spec") or {}
    if kind == "Pod":
        return spec
    if kind in ("Deployment", "StatefulSet", "Job"):
        return (spec.get("template") or {}).get("spec") or {}
    if kind == "CronJob":
        job = (spec.get("jobTemplate") or {}).get("spec") or {}
        return (job.get("template") or {}).get("spec") or {}
    return None


errors, checked, daemonsets = [], 0, []
ms_file, manifests = sys.argv[1], sys.argv[2:]
for p in problems(json.load(open(ms_file))):
    errors.append(f"{ms_file}: metrics-server: {p}")
checked += 1
for f in manifests:
    for doc in yaml.safe_load_all(open(f)):
        if not isinstance(doc, dict):
            continue
        name = f"{doc.get('kind')}/{(doc.get('metadata') or {}).get('name')}"
        if doc.get("kind") == "DaemonSet":
            daemonsets.append(name)
            continue
        spec = pod_spec(doc)
        if spec is None:
            continue
        checked += 1
        for p in problems(spec):
            errors.append(f"{f}: {name}: {p}")

if daemonsets:
    print("DaemonSets, not checked (every node by design): " + ", ".join(daemonsets))
if errors:
    print("\n".join(errors))
    print(f"{len(errors)} problem(s) in {checked} pod templates")
    sys.exit(1)
print(f"{checked} platform pod templates on pool system, tolerating {TAINT_KEY}")
