# Sourced by run.sh and eks/run.sh. The llm-d-router-standalone chart
# (v1.0.0 and main at ROUTER_MAIN_COMMIT) sets no upstream idle timeout on
# the clusters that send to the model servers, so Envoy keeps idle pooled
# connections for its default of 1 h and vLLM (keep-alive 5 s) always closes
# them first; a request written in the last milliseconds before that close
# fails with a 503 "connection termination" (flag UC). Evidence:
# docs/evidence/keepalive-race-2026-11-26.md.
# Until the chart has a value for it, this sets the upstream idle timeout on
# the rendered Envoy ConfigMap, below vLLM's keep-alive, with the same code
# the evidence tested (../keepalive-race/envoy_patch.py, arm idle).
# ENVOY_UPSTREAM_IDLE_S (versions.env, default 4) = off keeps the chart's
# Envoy config, as every run before 2026-11-26 had it.
# Needs python3 with PyYAML: PY, else the venv of ci/install-tools.sh when
# present (CI), else python3.
ENVOY_IDLE_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../keepalive-race" && pwd)/envoy_patch.py"
ENVOY_IDLE_VENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.ci-bin/venv/bin/python"
if [ -z "${PY:-}" ] && [ -x "$ENVOY_IDLE_VENV" ]; then PY=$ENVOY_IDLE_VENV; fi

# envoy_upstream_idle NAMESPACE [restart]: patch the router's Envoy ConfigMap;
# with "restart", roll the router so Envoy loads it (not needed when a
# template change rolls it anyway).
envoy_upstream_idle() {
  local ns=$1 restart=${2:-} s=${ENVOY_UPSTREAM_IDLE_S:-4} cm
  if [ "$s" = off ]; then echo "envoy upstream idle timeout: off (chart default, 1 h)"; return 0; fi
  cm=$(kubectl -n "$ns" get configmap -o json | "${PY:-python3}" -c 'import json,sys; print(next(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if any(x.endswith("envoy.yaml") for x in c.get("data", {}))))')
  kubectl -n "$ns" get configmap "$cm" -o json | IDLE_S=$s "${PY:-python3}" "$ENVOY_IDLE_PATCH" idle | kubectl -n "$ns" replace -f - >/dev/null
  if [ "$restart" = restart ]; then kubectl -n "$ns" rollout restart deploy/router-epp >/dev/null; fi
  echo "envoy upstream idle timeout: ${s}s on configmap $cm"
}
