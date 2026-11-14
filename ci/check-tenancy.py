"""Each team is confined to its namespace and has a CPU/memory quota owned by the
platform. Ported from gke-llm-inference-platform; on EKS there is no GPU, so the
GPU quota is optional and CPU/memory is the spending cap."""
import glob, os, sys
import yaml

root = sys.argv[1] if len(sys.argv) > 1 else "."
REPO = "https://github.com/MicheleCampi/eks-llm-inference-platform"
GROUP = "inference.michelecampi.dev"
PROTECTED = {"resourcequotas", "limitranges", "networkpolicies", "roles", "rolebindings"}
WRITE = {"create", "update", "patch", "delete", "deletecollection", "escalate", "bind", "impersonate"}
errs = []


def docs(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d]


files = sorted(glob.glob(os.path.join(root, "gitops/apps/team-*.yaml")))
if not files:
    errs.append("no team found in argocd/apps/team-*.yaml")
for f in files:
    t = os.path.basename(f)[len("team-"):-len(".yaml")]
    ns = "team-" + t
    ds = {(d["kind"], d["metadata"]["name"]): d for d in docs(f)}
    p = ds.get(("AppProject", ns))
    if not p:
        errs.append(f"{t}: no AppProject {ns}")
        continue
    s = p["spec"]
    if s.get("clusterResourceWhitelist"):
        errs.append(f"{t}: team project may manage cluster-scoped resources")
    for k in s.get("namespaceResourceWhitelist") or []:
        if k.get("group") != GROUP:
            errs.append(f"{t}: team project may manage {k.get('kind')}")
    if [d.get("namespace") for d in s.get("destinations") or []] != [ns]:
        errs.append(f"{t}: team project destinations are not exactly {ns}")
    if s.get("sourceRepos") != [REPO]:
        errs.append(f"{t}: team project sourceRepos are not exactly this repository")
    for app, proj, path in (("tenant-" + t, "tenancy", "gitops/tenants/" + t), (ns, ns, "gitops/teams/" + t)):
        a = ds.get(("Application", app))
        if not a:
            errs.append(f"{t}: no Application {app}")
            continue
        sp = a["spec"]
        if sp.get("project") != proj or sp["source"].get("path") != path or sp["destination"].get("namespace") != ns:
            errs.append(f"{t}: Application {app} must use project {proj}, path {path}, namespace {ns}")
    ten = [d for g in sorted(glob.glob(os.path.join(root, "gitops", "tenants", t, "*.yaml"))) for d in docs(g)]
    if not any(d["kind"] == "Namespace" and d["metadata"]["name"] == ns for d in ten):
        errs.append(f"{t}: tenants/{t} has no Namespace {ns}")
    # Quota caps CPU/memory; pods that declare none (the operator sets them only when the
    # spec does, since v0.9.0) get LimitRange defaults, without which they are rejected.
    if not any(d["kind"] == "ResourceQuota" and d["metadata"].get("namespace") == ns
               and {"requests.cpu", "requests.memory"} <= set(d["spec"].get("hard", {})) for d in ten):
        errs.append(f"{t}: tenants/{t} quota does not cap CPU and memory")
    if not any(d["kind"] == "LimitRange" and d["metadata"].get("namespace") == ns
               and any({"cpu", "memory"} <= set(l.get("defaultRequest", {}))
                       and {"cpu", "memory"} <= set(l.get("default", {}))
                       for l in d["spec"].get("limits", []) if l.get("type") == "Container")
               for d in ten):
        errs.append(f"{t}: tenants/{t} has no LimitRange with CPU/memory defaults for containers")
    # Default-deny ingress: every pod selected, Ingress in policyTypes.
    if not any(d["kind"] == "NetworkPolicy" and d["metadata"].get("namespace") == ns
               and d["spec"].get("podSelector") == {} and "Ingress" in d["spec"].get("policyTypes", [])
               for d in ten):
        errs.append(f"{t}: tenants/{t} has no default-deny ingress NetworkPolicy")
    # Team identity: a Role bound only to the team's own ServiceAccounts; the Role may not
    # use wildcards nor change the limits the platform set (quota, LimitRange, policy, RBAC).
    roles = {d["metadata"]["name"]: d for d in ten if d["kind"] == "Role" and d["metadata"].get("namespace") == ns}
    sas = {d["metadata"]["name"] for d in ten if d["kind"] == "ServiceAccount" and d["metadata"].get("namespace") == ns}
    if not any(d["kind"] == "RoleBinding" and d["metadata"].get("namespace") == ns
               and d["roleRef"].get("kind") == "Role" and d["roleRef"].get("name") in roles
               and d.get("subjects") and all(x.get("kind") == "ServiceAccount" and x.get("name") in sas
                                             and x.get("namespace", ns) == ns for x in d["subjects"])
               for d in ten):
        errs.append(f"{t}: tenants/{t} has no RoleBinding of a team Role to a team ServiceAccount")
    for name, r in sorted(roles.items()):
        for rule in r.get("rules") or []:
            if "*" in (rule.get("apiGroups") or []) + (rule.get("resources") or []) + (rule.get("verbs") or []):
                errs.append(f"{t}: Role {name} uses a wildcard")
            hit = set(rule.get("resources") or []) & PROTECTED
            if hit and set(rule.get("verbs") or []) & WRITE:
                errs.append(f"{t}: Role {name} may change {', '.join(sorted(hit))}")
    for g in sorted(glob.glob(os.path.join(root, "gitops", "teams", t, "*.yaml"))):
        for d in docs(g):
            if d["metadata"].get("namespace", ns) != ns:
                errs.append(f"{t}: {os.path.relpath(g, root)} targets namespace {d['metadata']['namespace']}")
for e in errs:
    print("FAIL:", e)
if errs:
    sys.exit(1)
print(f"tenancy OK: {len(files)} team(s)")
