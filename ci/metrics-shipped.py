"""Every metric that the alert rules and the dashboards use must pass a keep
filter of Alloy (any prometheus.relabel on __name__), or its alert or panel can
never show data. Usage: metrics-shipped.py ALLOY_CONFIG FILE..."""
import re, sys
alloy = open(sys.argv[1]).read()
keeps = [re.compile(r) for r in re.findall(
    r'source_labels\s*=\s*\["__name__"\]\s*\n\s*regex\s*=\s*"([^"]+)"\s*\n\s*action\s*=\s*"keep"', alloy)]
assert keeps, "no keep filter on __name__ found in the Alloy configuration"
used = set()
for f in sys.argv[2:]:
    used |= set(re.findall(r"\b(?:karpenter|container|kube)_[a-z_]+", open(f).read()))
missing = sorted(m for m in used if not any(k.fullmatch(m) for k in keeps))
print(f"{len(used)} metrics used, {len(keeps)} keep filters")
if missing:
    print("not shipped by alloy: " + ", ".join(missing)); sys.exit(1)
