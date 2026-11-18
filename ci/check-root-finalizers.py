"""The root app ignores only the finalizers Argo CD itself adds for PreDelete
hooks, so it does not stay OutOfSync forever (live #4, 18/11) and still
enforces the finalizers Git declares.
Usage: check-root-finalizers.py ROOT_APP RENDERED_CHART...

Argo CD v3 adds pre-delete-finalizer.argocd.argoproj.io (and .../cleanup) to an
Application whose resources carry a PreDelete hook (Helm pre-delete hooks
count). Git does not declare them, so the parent app (root) sees the child
Application differ on metadata.finalizers. Live #4: Application kyverno, whose
chart has the webhooksCleanup pre-delete Job; spec identical, root OutOfSync.

Fails when a rendered chart has a pre-delete hook and root does not ignore
those finalizers with a jqPathExpression on Application, when root ignores
the whole /metadata/finalizers (that would also hide a missing
resources-finalizer), or when RespectIgnoreDifferences is not set (selfHeal
would otherwise strip the finalizers Argo CD needs at delete time)."""
import sys
import yaml

root_file, charts = sys.argv[1], sys.argv[2:]
MARK = "pre-delete-finalizer.argocd.argoproj.io"

hooked = []
for f in charts:
    for d in yaml.safe_load_all(open(f)):
        if not isinstance(d, dict):
            continue
        ann = (d.get("metadata") or {}).get("annotations") or {}
        helm = str(ann.get("helm.sh/hook", ""))
        argo = str(ann.get("argocd.argoproj.io/hook", ""))
        if "pre-delete" in helm.split(",") or "PreDelete" in argo.split(","):
            hooked.append(f"{f}: {d.get('kind')}/{(d.get('metadata') or {}).get('name')}")

root = yaml.safe_load(open(root_file))
spec = root.get("spec") or {}
errors = []
jq_ok = False
for e in spec.get("ignoreDifferences") or []:
    if e.get("kind") != "Application":
        continue
    if "/metadata/finalizers" in (e.get("jsonPointers") or []):
        errors.append("root ignores all of /metadata/finalizers: a missing resources-finalizer would go unseen")
    if e.get("group") == "argoproj.io" and any(MARK in x for x in e.get("jqPathExpressions") or []):
        jq_ok = True
opts = ((spec.get("syncPolicy") or {}).get("syncOptions")) or []

if not hooked:
    errors.append("no pre-delete hook found in the rendered charts: live #4 saw one in kyverno, so detection or the render broke")
else:
    if not jq_ok:
        errors.append(f"charts with pre-delete hooks, but root does not ignore {MARK}* on Application")
    if "RespectIgnoreDifferences=true" not in opts:
        errors.append("root ignores the PreDelete finalizers but sync would still remove them: add RespectIgnoreDifferences=true")

for e in errors:
    print("FAIL:", e)
if errors:
    sys.exit(1)
print(f"OK: {len(hooked)} pre-delete hook(s) in the rendered charts, root ignores only Argo CD's PreDelete finalizers")
for h in hooked:
    print("  ", h)
