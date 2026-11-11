"""Controller policies from Karpenter's official CloudFormation, as templatefile() inputs.
Usage: extract.py CFN OUTDIR [--check]"""
import re, sys, pathlib
SUBS = {"AWS::Partition": "partition", "AWS::Region": "region", "AWS::AccountId": "account_id",
        "ClusterName": "cluster_name", "KarpenterInterruptionQueue.Arn": "queue_arn",
        "KarpenterNodeRole.Arn": "node_role_arn"}
cfn, out, check = sys.argv[1], pathlib.Path(sys.argv[2]), "--check" in sys.argv
lines, name, docs, i = open(cfn).read().split("\n"), None, {}, 0
while i < len(lines):
    m = re.match(r"^  (\w+):$", lines[i])
    if m: name = m.group(1)
    if lines[i].strip() == "PolicyDocument: !Sub |":
        body, i = [], i + 1
        while i < len(lines) and (not lines[i].strip() or lines[i].startswith(" " * 8)):
            body.append(lines[i][8:]); i += 1
        text = "\n".join(body).strip() + "\n"
        assert "%{" not in text
        docs[name] = re.sub(r"\$\{([^}]+)\}", lambda x: "${" + SUBS[x.group(1)] + "}", text)
        continue
    i += 1
assert len(docs) == 6, sorted(docs)
bad = [n for n, t in docs.items() if check and (out / f"{n}.json.tpl").read_text() != t]
if check: sys.exit(f"stale: {bad}" if bad else 0)
for n, t in docs.items(): (out / f"{n}.json.tpl").write_text(t)
print(sorted(docs))
