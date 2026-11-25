"""Every Argo CD Application targets a destination its AppProject allows, so a
wrong project or namespace fails in CI instead of at sync time (InvalidSpecError,
PR #34 on 15/11). Usage: check-app-destinations.py FILE...
AppProjects and Applications are read from the FILEs. An Application fails if it
uses project default (closed on purpose), a project not found in the FILEs, or a
destination no entry of its project matches. Matching follows Argo CD: glob on
server (or name, when the Application targets a cluster by name) and namespace.
A field missing from a project destination matches nothing; deny entries ("!")
are not used here and are refused rather than half-implemented. The template
of an ApplicationSet is checked as the Application it generates."""
import sys
from fnmatch import fnmatchcase
import yaml

files = sys.argv[1:]
projects, apps = {}, []
for f in files:
    for d in yaml.safe_load_all(open(f)):
        if not isinstance(d, dict) or not str(d.get("apiVersion", "")).startswith("argoproj.io/"):
            continue
        if d.get("kind") == "AppProject":
            projects[d["metadata"]["name"]] = d.get("spec") or {}
        elif d.get("kind") == "Application":
            apps.append((f, d))
        elif d.get("kind") == "ApplicationSet":
            apps.append((f, d["spec"]["template"]))
if not apps:
    sys.exit("FAIL: no Application found in " + " ".join(files))


def allowed(dest, rule):
    patterns = [v for v in rule.values() if isinstance(v, str)]
    if any(p.startswith("!") for p in patterns):
        raise ValueError(f"deny destination {rule} not supported by this check")
    ns = fnmatchcase(dest.get("namespace", ""), rule.get("namespace", "\0"))
    if dest.get("server"):
        return ns and fnmatchcase(dest["server"], rule.get("server", "\0"))
    return ns and fnmatchcase(dest.get("name", ""), rule.get("name", "\0"))


bad = []
for f, a in apps:
    name, spec = a["metadata"]["name"], a.get("spec") or {}
    project, dest = spec.get("project", "default"), spec.get("destination") or {}
    where = f"{dest.get('server') or dest.get('name')} namespace {dest.get('namespace', '(none)')}"
    if project == "default":
        bad.append(f"{name} ({f}): uses project default, which allows nothing")
    elif project not in projects:
        bad.append(f"{name} ({f}): project {project} not found")
    else:
        try:
            ok = any(allowed(dest, r) for r in projects[project].get("destinations") or [])
        except ValueError as e:
            sys.exit(f"FAIL: project {project}: {e}")
        if not ok:
            bad.append(f"{name} ({f}): destination {where} not allowed by project {project}")
if bad:
    sys.exit("FAIL: Application destinations outside their AppProject:\n  " + "\n  ".join(bad))
print(f"app-destinations: {len(apps)} applications inside their project")
