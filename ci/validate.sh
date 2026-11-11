#!/usr/bin/env bash
# Every check of this repo, offline of AWS: no credentials, rerunnable by anyone.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${CI_BIN:-$PWD/.ci-bin}:$PATH"
terraform version | sed -n 1p  # sed reads to the end: head -1 can SIGPIPE terraform under pipefail (exit 141)
terraform fmt -check -recursive
terraform init -backend=false -input=false >/dev/null
terraform validate -no-color
terraform test -no-color
echo "7ffeb01f04b5da482ef43087830de00a476098416e3b4576c38239ef1b0bef4b  ci/karpenter/cloudformation-v1.15.1.yaml" | sha256sum -c -
python3 -I ci/karpenter/extract.py ci/karpenter/cloudformation-v1.15.1.yaml modules/eks/karpenter-policies --check
gitleaks git --no-banner --redact .
actionlint .github/workflows/*.yml
echo "ALL PASS"
