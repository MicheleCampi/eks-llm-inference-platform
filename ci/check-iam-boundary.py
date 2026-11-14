"""Every aws_iam_role under the given directory must set permissions_boundary.

The apply role may create IAM roles only with eks-llm-boundary
(bootstrap/ci-identity/apply.tf); a role without it fails at apply time, so
CI rejects it first. Also fails if no role is found, so it cannot pass empty.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
found, bad = 0, []
for f in sorted(root.rglob("*.tf")):
    for m in re.finditer(r'^resource "aws_iam_role" "([^"]+)" \{\n(.*?)^\}', f.read_text(), re.M | re.S):
        found += 1
        if not re.search(r"^\s*permissions_boundary\s*=", m.group(2), re.M):
            bad.append(f"{f}: aws_iam_role.{m.group(1)}")
if not found:
    sys.exit(f"FAIL: no aws_iam_role found under {root}")
if bad:
    sys.exit("FAIL: aws_iam_role without permissions_boundary:\n  " + "\n  ".join(bad))
print(f"OK: {found} aws_iam_role under {root}, all with permissions_boundary")
