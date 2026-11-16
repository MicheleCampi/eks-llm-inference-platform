"""Invariants of the Karpenter pools that a schema cannot express.

Every NodePool: a cost cap (spec.limits), bounded node life and drain
(expireAfter, terminationGracePeriod), explicit disruption budgets, a pool
label equal to its name, an existing EC2NodeClass. A pool that can launch GPU
instances carries the nvidia.com/gpu NoSchedule taint, and a pool without it
cannot launch them, so CPU pods never land on a GPU node. Every EC2NodeClass:
IMDSv2 required with hop limit 1 (pods cannot reach the node role), a pinned
AMI release, the Project cost tag of providers.tf.

Usage: check-nodepools.py FILE...   (all NodePools and EC2NodeClasses)
"""
import re, sys, yaml

POOL_LABEL = "platform.michelecampi.dev/pool"
GPU_TAINT = {"key": "nvidia.com/gpu", "effect": "NoSchedule"}
# Instance families with GPUs or other accelerators (g*, p*, inf*, trn*, dl*).
GPU_FAMILY = re.compile(r"^(g|p|inf|trn|dl)\d")

want_project = re.search(r'Project\s*=\s*"([^"]+)"', open("providers.tf").read()).group(1)
docs = [d for f in sys.argv[1:] for d in yaml.safe_load_all(open(f)) if d]
pools = [d for d in docs if d["kind"] == "NodePool"]
classes = {d["metadata"]["name"]: d for d in docs if d["kind"] == "EC2NodeClass"}
errors = []


def can_launch_gpu(reqs):
    """True unless the requirements exclude every accelerator type."""
    by_key = {r["key"]: r for r in reqs}
    t = by_key.get("node.kubernetes.io/instance-type")
    if t and t["operator"] == "In":
        return any(GPU_FAMILY.match(v) for v in t["values"])
    c = by_key.get("karpenter.k8s.aws/instance-category")
    if c and c["operator"] == "In":
        return any(v in ("g", "p", "inf", "trn", "dl") for v in c["values"])
    n = by_key.get("karpenter.k8s.aws/instance-gpu-count")
    if n and n["operator"] == "DoesNotExist":
        return False
    return True


for p in pools:
    name, spec = p["metadata"]["name"], p["spec"]
    tmpl = spec["template"]
    ts = tmpl["spec"]
    if not spec.get("limits"):
        errors.append(f"NodePool {name}: no spec.limits (no cost cap)")
    if ts.get("expireAfter") in (None, "Never"):
        errors.append(f"NodePool {name}: expireAfter unset or Never (AMI updates never reach old nodes)")
    if not ts.get("terminationGracePeriod"):
        errors.append(f"NodePool {name}: no terminationGracePeriod (a PDB can block a drain forever)")
    if not (spec.get("disruption") or {}).get("budgets"):
        errors.append(f"NodePool {name}: no disruption.budgets")
    if ((tmpl.get("metadata") or {}).get("labels") or {}).get(POOL_LABEL) != name:
        errors.append(f"NodePool {name}: label {POOL_LABEL} must equal the pool name")
    ref = ts["nodeClassRef"]["name"]
    if ref not in classes:
        errors.append(f"NodePool {name}: EC2NodeClass {ref} not found")
    tainted = any(all(t.get(k) == v for k, v in GPU_TAINT.items()) for t in ts.get("taints") or [])
    gpu = can_launch_gpu(ts["requirements"])
    if gpu and not tainted:
        errors.append(f"NodePool {name}: can launch GPU instances without the nvidia.com/gpu NoSchedule taint")
    if tainted and not gpu:
        errors.append(f"NodePool {name}: nvidia.com/gpu taint on a pool that cannot launch GPU instances")

for name, c in classes.items():
    spec = c["spec"]
    md = spec.get("metadataOptions") or {}
    if md.get("httpTokens") != "required" or md.get("httpPutResponseHopLimit") != 1:
        errors.append(f"EC2NodeClass {name}: IMDSv2 must be required with hop limit 1")
    for term in spec.get("amiSelectorTerms") or []:
        alias = term.get("alias", "")
        if alias and not re.fullmatch(r"[a-z0-9]+@v\d{8}", alias):
            errors.append(f"EC2NodeClass {name}: AMI alias {alias!r} is not a pinned release")
    got = (spec.get("tags") or {}).get("Project")
    if got != want_project:
        errors.append(f"EC2NodeClass {name}: tag Project is {got!r}, providers.tf has {want_project!r}")

if not pools:
    errors.append("no NodePool found")
for e in errors:
    print("FAIL " + e)
if errors:
    sys.exit(1)
print(f"nodepools OK: {len(pools)} NodePools, {len(classes)} EC2NodeClasses")
