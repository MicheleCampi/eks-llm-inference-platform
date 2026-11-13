"""Every karpenter_* metric that the alert rules and the dashboard use must
pass the keep filter of Alloy, or its alert can never fire.
Usage: metrics-shipped.py ALLOY_CONFIG FILE..."""
import re, sys
alloy = open(sys.argv[1]).read()
block = alloy[alloy.index('prometheus.relabel "karpenter"'):]
keep = re.compile(re.search(r'regex\s*=\s*"([^"]+)"', block).group(1))
used = set()
for f in sys.argv[2:]:
    used |= set(re.findall(r"karpenter_[a-z_]+", open(f).read()))
missing = sorted(m for m in used if not keep.fullmatch(m))
print(f"{len(used)} karpenter metrics used")
if missing:
    print("not shipped by alloy: " + ", ".join(missing)); sys.exit(1)
