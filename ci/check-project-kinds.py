"""Every cluster-scoped object an AppProject's apps create is in that project's
clusterResourceWhitelist, so Argo CD never refuses a sync live.
Usage: check-project-kinds.py PROJECTS_YAML PROJECT FILE...
Each file is parsed on its own (concatenating YAML files merges documents).
Custom kinds: scope read from the CRDs found in FILEs. Built-in kinds: the list
below (no offline source without a cluster): a rare built-in kind missing here
would not be checked."""
import sys, yaml
BUILTIN = {("", "Namespace"), ("", "Node"), ("", "PersistentVolume"),
    ("rbac.authorization.k8s.io", "ClusterRole"), ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    ("apiextensions.k8s.io", "CustomResourceDefinition"), ("storage.k8s.io", "StorageClass"),
    ("storage.k8s.io", "CSIDriver"), ("scheduling.k8s.io", "PriorityClass"),
    ("admissionregistration.k8s.io", "ValidatingWebhookConfiguration"),
    ("admissionregistration.k8s.io", "MutatingWebhookConfiguration"),
    ("admissionregistration.k8s.io", "ValidatingAdmissionPolicy"),
    ("admissionregistration.k8s.io", "ValidatingAdmissionPolicyBinding"),
    ("apiregistration.k8s.io", "APIService"), ("networking.k8s.io", "IngressClass"),
    ("node.k8s.io", "RuntimeClass"), ("flowcontrol.apiserver.k8s.io", "FlowSchema"),
    ("flowcontrol.apiserver.k8s.io", "PriorityLevelConfiguration")}
projects_file, name, files = sys.argv[1], sys.argv[2], sys.argv[3:]
proj = next(d for d in yaml.safe_load_all(open(projects_file)) if d and d.get("kind") == "AppProject" and d["metadata"]["name"] == name)
allowed = {(w.get("group", ""), w["kind"]) for w in proj["spec"].get("clusterResourceWhitelist") or []}
docs = []
for f in files:
    for d in yaml.safe_load_all(open(f)):
        if isinstance(d, dict) and d.get("kind") and d.get("apiVersion"):
            docs.append((f, d))
scope = {(d["spec"]["group"], d["spec"]["names"]["kind"]): d["spec"].get("scope") for _, d in docs if d["kind"] == "CustomResourceDefinition"}
bad = set()
for f, d in docs:
    g = d["apiVersion"].split("/")[0] if "/" in d["apiVersion"] else ""
    k = (g, d["kind"])
    if (k in BUILTIN or scope.get(k) == "Cluster") and k not in allowed:
        bad.add(f"{g or 'core'}/{d['kind']} ({f})")
if bad:
    sys.exit(f"FAIL: cluster-scoped kinds not in AppProject {name}: " + ", ".join(sorted(bad)))
print(f"project kinds OK: {name}, {len(docs)} objects, {len(allowed)} allowed cluster-scoped kinds")
