"""Every Argo CD Application sourced from this repo deploys the same release
tag (vX.Y.Z), never a branch: promotion is a reviewed change plus a tag.
Usage: check-release-pin.py REPO_URL FILE..."""
import re, sys, yaml
repo, files = sys.argv[1], sys.argv[2:]
pins = {}
for f in files:
    for d in yaml.safe_load_all(open(f)):
        if not (isinstance(d, dict) and d.get("kind") == "Application"):
            continue
        for s in [d["spec"].get("source")] + (d["spec"].get("sources") or []):
            if s and s.get("repoURL") == repo:
                pins[d["metadata"]["name"]] = s.get("targetRevision")
bad = {a: r for a, r in pins.items() if not re.fullmatch(r"v\d+\.\d+\.\d+", str(r))}
if bad:
    sys.exit(f"FAIL: not a release tag: {bad}")
if len(set(pins.values())) != 1:
    sys.exit(f"FAIL: apps deploy different releases: {pins}")
print(f"release pin OK: {len(pins)} apps on {next(iter(pins.values()))}")
