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
gitleaks git --no-banner --redact .
actionlint .github/workflows/*.yml
echo "ALL PASS"
