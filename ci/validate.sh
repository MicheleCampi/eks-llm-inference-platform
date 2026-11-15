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
terraform -chdir=modules/vpc init -backend=false -input=false >/dev/null
terraform -chdir=modules/vpc test -no-color
# CI identity (applied once, out of the cluster stack): trust and state access asserted.
terraform -chdir=bootstrap/ci-identity init -backend=false -input=false >/dev/null
terraform -chdir=bootstrap/ci-identity validate -no-color
terraform -chdir=bootstrap/ci-identity test -no-color
# Grafana as code: the lock file must already pin the provider (readonly).
terraform -chdir=observability/terraform init -backend=false -input=false -lockfile=readonly >/dev/null
terraform -chdir=observability/terraform validate -no-color
echo "7ffeb01f04b5da482ef43087830de00a476098416e3b4576c38239ef1b0bef4b  ci/karpenter/cloudformation-v1.15.1.yaml" | sha256sum -c -
python3 -I ci/karpenter/extract.py ci/karpenter/cloudformation-v1.15.1.yaml modules/eks/karpenter-policies --check
gitleaks git --no-banner --redact .
actionlint .github/workflows/*.yml
# The account id is masked from each AWS job's first log line; a job without the
# secret reference must be rejected (self-test on a copy without it).
PY="${CI_BIN:-$PWD/.ci-bin}/venv/bin/python"
"$PY" ci/check-account-mask.py .github/workflows/*.yml
NEG=$(mktemp); trap 'rm -f "$NEG"' EXIT
grep -v 'AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}' .github/workflows/apply.yml > "$NEG"
if out=$("$PY" ci/check-account-mask.py "$NEG" 2>&1); then echo "neg-account-mask: NOT rejected"; exit 1; fi
grep -q "job env AWS_ACCOUNT_ID is not" <<<"$out" || { echo "neg-account-mask: rejected for the wrong reason: $out"; exit 1; }
echo "neg-account-mask: rejected as expected"
bash ci/validate-gitops.sh
echo "ALL PASS"
