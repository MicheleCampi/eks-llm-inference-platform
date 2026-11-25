"""Every Karpenter node carries the cost allocation tags of Terraform's
default_tags: Project (the AWS Budget filter) and Session (the BUDGET entry of
the live session, which splits the cost of two sessions on the same day).

Project is static: equal in every EC2NodeClass and in providers.tf. Session
changes at every session, so Git cannot hold it: ApplicationSet
karpenter-nodes adds it with a kustomize patch from the label of the Argo CD
cluster secret. This check renders that patch with a test value, applies it
to each EC2NodeClass given, and asserts both tags; it also asserts that the
kustomization lists every EC2NodeClass file, and that providers.tf sets
Session from var.session.
Usage: check-cost-tags.py APPLICATIONSET KUSTOMIZATION NODECLASS..."""
import glob, os, re, sys, yaml

LABEL = "platform.michelecampi.dev/session"
TEST = "A-999"
appset_file, kust_file, nodeclass_files = sys.argv[1], sys.argv[2], sys.argv[3:]
providers = open("providers.tf").read()
want = re.search(r'Project\s*=\s*"([^"]+)"', providers).group(1)
errors = []
if not re.search(r'^\s*Session\s*=\s*var\.session\s*$', providers, re.M):
    errors.append("providers.tf: local.tags has no Session = var.session")

appset = yaml.safe_load(open(appset_file))
spec = appset.get("spec") or {}
sel = [e for g in spec.get("generators") or [] for e in (((g.get("clusters") or {}).get("selector") or {}).get("matchExpressions") or [])]
if {"key": LABEL, "operator": "Exists"} not in sel:
    errors.append(f"{appset_file}: the cluster generator must select clusters labelled {LABEL} (fail closed)")
patches = (((spec.get("template") or {}).get("spec") or {}).get("source") or {}).get("kustomize", {}).get("patches") or []
ops = []
for p in patches:
    if (p.get("target") or {}).get("kind") == "EC2NodeClass":
        text = p["patch"].replace('{{ index .metadata.labels "%s" }}' % LABEL, TEST)
        ops += yaml.safe_load(text)
if not ops:
    errors.append(f"{appset_file}: no kustomize patch on EC2NodeClass")

kust_dir = os.path.dirname(kust_file)
listed = set((yaml.safe_load(open(kust_file)) or {}).get("resources") or [])
for f in sorted(glob.glob(os.path.join(kust_dir, "ec2nodeclass*.yaml"))):
    if os.path.basename(f) not in listed:
        errors.append(f"{kust_file}: {os.path.basename(f)} not listed, Argo CD would not deploy it")

for f in nodeclass_files:
    for d in yaml.safe_load_all(open(f)):
        if not d or d.get("kind") != "EC2NodeClass":
            continue
        tags = dict((d.get("spec") or {}).get("tags") or {})
        if "Session" in tags:
            errors.append(f"{f}: Session is set in Git; it must come from the cluster label")
        for op in ops:
            if op.get("op") == "add" and op.get("path") == "/spec/tags/Session" and (d.get("spec") or {}).get("tags") is not None:
                tags["Session"] = op["value"]
        name = d["metadata"]["name"]
        if tags.get("Project") != want:
            errors.append(f"EC2NodeClass {name}: tag Project is {tags.get('Project')!r}, providers.tf default_tags has {want!r}")
        if tags.get("Session") != TEST:
            errors.append(f"EC2NodeClass {name}: tag Session is {tags.get('Session')!r} after the ApplicationSet patch, expected the cluster label")
if errors:
    sys.exit("FAIL: " + "\n  ".join(errors))
print(f"cost tags OK: Project={want}, Session from cluster label {LABEL} on {len(nodeclass_files)} EC2NodeClass files")
