#!/usr/bin/env bash
# The keep-alive race against real vLLM, behind the real chart, on kind.
# Protocol: KIND.md (written before the run).
#   bash kind.sh backend                one vLLM replica (keep-alive 5 s)
#   bash kind.sh ARM NAME GAP_MIN GAP_MAX N
# ARM = chart | idle | retry, applied to the chart's rendered Envoy config by
# envoy_patch.py (IDLE_S, RETRY_ON from the environment).
# Expects the prefix-routing kind cluster (../prefix-routing/run.sh up) with
# the vLLM image loaded, and ROUTER_SRC, a llm-d-router checkout at
# ROUTER_MAIN_COMMIT. One model server replica, so the EPP has one pod to pick and one Envoy worker keeps one pooled
# connection to it: the gap the client waits is the idle time of that
# connection, plus the EPP's own time.
# Needs: kubectl, helm, python3 with PyYAML.
set -euo pipefail
cd "$(dirname "$0")"
. ../prefix-routing/versions.env
arm=$1 name=${2:-} gmin=${3:-} gmax=${4:-} n=${5:-}
PY=${PY:-python3}
mkdir -p results
k() { kubectl -n "$NS" "$@"; }
say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a results/kind.log; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

if [ "$arm" = backend ]; then
  # One vLLM replica from the start, keep-alive at the vLLM default of 5 s.
  # Two replicas starting together on a 4-core runner did not reach Ready
  # within the 900 s of ../prefix-routing/run.sh (run 45880218897), as in
  # KEEPALIVE.md's 1 s condition; one replica needs half the CPU to start.
  sed -e "s|__MODEL__|$MODEL|" -e "s|__MODEL_REVISION__|$MODEL_REVISION|" -e "s|__KEEPALIVE__|5|" \
      -e 's|^  replicas: 2$|  replicas: 1|' ../prefix-routing/manifests/vllm.yaml | k apply -f - >/dev/null
  [ "$(k get statefulset model -o jsonpath='{.spec.replicas}')" = 1 ] || { echo "replicas not 1"; exit 1; }
  t0=$SECONDS
  until [ "$(k get statefulset model -o jsonpath='{.status.readyReplicas}')" = 1 ]; do
    [ $((SECONDS - t0)) -lt 1500 ] || { k logs model-0 --tail=50 || true; exit 1; }
    echo "$((SECONDS - t0)) s: $(k get pods -l app=model --no-headers | awk '{print $1" "$2" "$3}')"
    sleep 15
  done
  say "vllm: 1 replica Ready after $((SECONDS - t0)) s"
  exit 0
fi
say "model servers: $(k get pods -l app=model -o wide --no-headers | awk '{print $1" "$2" "$3}')"
say "vllm keep-alive: $(k get statefulset model -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VLLM_HTTP_TIMEOUT_KEEP_ALIVE")].value}') s; uvicorn $(k exec model-0 -- python3 -c 'import importlib.metadata as m; print(m.version("uvicorn"), "httptools", m.version("httptools"), "uvloop", m.version("uvloop"))')"

[ "$(git -C "${ROUTER_SRC:?ROUTER_SRC: llm-d-router checkout}" rev-parse HEAD)" = "$ROUTER_MAIN_COMMIT" ] || { echo "ROUTER_SRC is not at $ROUTER_MAIN_COMMIT"; exit 1; }
chart="$ROUTER_SRC/config/charts/llm-d-router-standalone"
img=${ROUTER_MAIN_EPP_IMAGE_REMOTE%%:*} ref=${ROUTER_MAIN_EPP_IMAGE_REMOTE#*:}
helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
helm dependency build --skip-refresh "$chart" >/dev/null
helm upgrade -i router "$chart" -n "$NS" --wait --timeout 300s \
  -f ../prefix-routing/values/router.yaml -f ../prefix-routing/values/legacy.yaml \
  --set router.epp.image.registry="${img%/*}" --set router.epp.image.repository="${img##*/}" \
  --set router.epp.image.tag="$ref" --set router.proxy.image="$ROUTER_MAIN_ENVOY_IMAGE" >/dev/null
cm=$(k get configmap -o json | "$PY" -c 'import json,sys; print(next(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if any(x.endswith("envoy.yaml") for x in c.get("data", {}))))')
k get configmap "$cm" -o json | "$PY" envoy_patch.py "$arm" 2> >(tee -a results/kind.log >&2) | k replace -f - >/dev/null
k rollout restart deploy/router-epp >/dev/null
k rollout status deploy/router-epp --timeout=300s | tee -a results/kind.log
sleep 15  # EPP discovers the pod and scrapes its metrics at least once
say "arm $arm ($name): $(k get pods --no-headers | awk '/^router-epp/ && $3 == "Running" {print $1}' | paste -sd' '), gap [$gmin, $gmax] s, $n requests"

k create configmap race-client --from-file=client.py --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
k delete pod race-client --ignore-not-found --wait >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: race-client
spec:
  restartPolicy: Never
  containers:
    - name: client
      image: $LOADGEN_IMAGE
      command: ["bash", "-c"]
      args:
        - pip install -q --disable-pip-version-check --root-user-action=ignore aiohttp==3.14.5 >&2 && exec python3 /app/client.py
      env:
        - {name: "URL", value: "http://router-epp:8081/v1/completions"}
        - {name: "MODEL", value: "$MODEL"}
        - {name: "PROMPT", value: "The keep-alive race, one short prompt."}
        - {name: "N", value: "$n"}
        - {name: "GAP_MIN", value: "$gmin"}
        - {name: "GAP_MAX", value: "$gmax"}
      resources:
        requests: {cpu: 100m, memory: 64Mi}
      volumeMounts:
        - {name: app, mountPath: /app}
  volumes:
    - name: app
      configMap: {name: race-client}
YAML
t0=$SECONDS
until [[ "$(k get pod race-client -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do
  [ $((SECONDS - t0)) -lt 3600 ] || { echo "client timed out"; exit 1; }
  sleep 10
done
k logs race-client | grep '^{' > "results/$name.jsonl"
k logs deploy/router-epp -c envoy-proxy --tail=-1 | grep '^{' > "results/$name.envoy.log" || true
[ "$(k get pod race-client -o jsonpath='{.status.phase}')" = Succeeded ] || { k logs race-client | tail -20; exit 1; }
"$PY" report.py "results/$name.jsonl" | tee -a results/kind.log
helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
