#!/usr/bin/env bash
# Fetch inference-platform-ci at the tag pinned in ci/platform-ci.env and
# require the tag to resolve to the pinned commit before running anything
# from it (so this check cannot come from its own lib.sh). Then install into
# $CI_BIN, each SHA-256 verified, the tools eks needs, and PyYAML (hash-locked) for ci/validate-gitops.sh.
# PLATFORM_CI_ENV replaces ci/platform-ci.env, for testing that a wrong pin
# fails.
set -euo pipefail
cd "$(dirname "$0")/.."
CI_BIN=${CI_BIN:-$PWD/.ci-bin}
. "${PLATFORM_CI_ENV:-ci/platform-ci.env}"
# Downloads from GitHub fail now and then (timeout on #9): 4 tries, 15/30/60 s apart.
retry() { local n=1 d=15; until "$@"; do [ $n -ge 4 ] && return 1; echo "retry $n/3 in ${d}s: $1 ${2:-}" >&2; sleep $d; n=$((n+1)); d=$((d*2)); done; }
P=$CI_BIN/platform-ci
rm -rf "$P" && mkdir -p "$CI_BIN" && git init -q "$P"
retry git -C "$P" fetch -q --depth 1 https://github.com/MicheleCampi/inference-platform-ci.git "refs/tags/$PLATFORM_CI_TAG:refs/tags/$PLATFORM_CI_TAG"
got=$(git -C "$P" rev-parse --verify -q "refs/tags/$PLATFORM_CI_TAG^{commit}")
if [ "$got" != "$PLATFORM_CI_COMMIT" ]; then echo "inference-platform-ci $PLATFORM_CI_TAG resolves to $got, not the pinned $PLATFORM_CI_COMMIT" >&2; exit 1; fi
git -C "$P" checkout -q "$PLATFORM_CI_COMMIT"
retry bash "$P/install.sh" "$CI_BIN" "$P/tools.lock" terraform gitleaks actionlint helm kubeconform yq openapi2jsonschema trivy
retry bash "$P/install-python.sh" "$CI_BIN/venv" "$P/requirements.lock"
