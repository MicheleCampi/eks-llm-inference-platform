"""Karpenter nodes carry the same Project tag as Terraform default_tags,
so a budget filtered on Project sees node spend."""
import re, sys, yaml
want = re.search(r'Project\s*=\s*"([^"]+)"', open("providers.tf").read()).group(1)
spec = yaml.safe_load(open(sys.argv[1]))["spec"]
got = (spec.get("tags") or {}).get("Project")
if got != want:
    sys.exit(f"FAIL: EC2NodeClass tag Project is {got!r}, providers.tf default_tags has {want!r}")
print(f"cost tags OK: Project={want}")
