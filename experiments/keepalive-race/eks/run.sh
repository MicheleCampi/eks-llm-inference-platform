#!/usr/bin/env bash
# The keep-alive race on EKS (protocol: EKS.md, written before the session).
# Runs from the operator's machine against the live cluster of
# docs/runbooks/live-a026.md (current kubectl context). One phase per command:
#   bash run.sh backend    one VllmService qwen-race per arm namespace (race-chart, race-idle)
#   bash run.sh arms       router + client in both namespaces at once, then the report
#   bash run.sh report     summary of results/*.jsonl
#   bash run.sh clean      both namespaces
#   bash run.sh client-yaml NS   the client pod manifest (CI admission check)
# Arms, as on kind (../KIND.md): chart = the chart's Envoy config; idle = the
# upstream idle timeout of ../prefix-routing/envoy-idle.sh (4 s, the fix
# every router install now carries). Both through llm-d-router main at
# ROUTER_MAIN_COMMIT with the legacy scorers (A-025 arm legacy), so ROUTER_SRC
# must be a llm-d-router checkout at that commit.
# Needs kubectl, helm (3.8+), python3 with PyYAML. Every wait prints one line
# per iteration; run `arms` under nohup (live-a026.md).
set -euo pipefail
cd "$(dirname "$0")"
. ../../prefix-routing/versions.env
APP=qwen-race
CLIENT_LABEL=inference.michelecampi.dev/client
ARMS=(chart idle)
N=${N:-241} GAP_MIN=${GAP_MIN:-4.90} GAP_MAX=${GAP_MAX:-5.00}
PY=${PY:-python3}
mkdir -p results
LOG=results/run.log
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

ready() {  # number of Ready, not terminating, model pods in namespace $1
  kubectl -n "$1" get pods -l "app=$APP" -o json | "$PY" -c '
import json, sys
ps = json.load(sys.stdin)["items"]
print(sum(1 for p in ps if not p["metadata"].get("deletionTimestamp")
          and any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))))'
}

router_up() {  # namespace, arm
  local ns=$1 arm=$2 chart="$ROUTER_SRC/config/charts/llm-d-router-standalone" cm
  local img=${ROUTER_MAIN_EPP_IMAGE_REMOTE%%:*} ref=${ROUTER_MAIN_EPP_IMAGE_REMOTE#*:}
  helm uninstall router -n "$ns" --wait >/dev/null 2>&1 || true
  helm upgrade -i router "$chart" -n "$ns" --wait --timeout 300s \
    -f ../../prefix-routing/values/router.yaml -f ../../prefix-routing/eks/router-eks.yaml \
    -f ../../prefix-routing/values/legacy.yaml --set "router.modelServers.matchLabels.app=$APP" \
    --set router.epp.image.registry="${img%/*}" --set router.epp.image.repository="${img##*/}" \
    --set router.epp.image.tag="$ref" --set router.proxy.image="$ROUTER_MAIN_ENVOY_IMAGE" >/dev/null
  cm=$(kubectl -n "$ns" get configmap -o json | "$PY" -c 'import json,sys; print(next(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if any(x.endswith("envoy.yaml") for x in c.get("data", {}))))')
  kubectl -n "$ns" get configmap "$cm" -o json | IDLE_S=${ENVOY_UPSTREAM_IDLE_S:-4} "$PY" ../envoy_patch.py "$arm" 2> >(tee -a "$LOG" >&2) | kubectl -n "$ns" replace -f - >/dev/null
  # The label patch rolls the pod, so Envoy starts with the patched config.
  kubectl -n "$ns" patch deploy router-epp --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"$CLIENT_LABEL\":\"$APP\"}}}}}" >/dev/null
  kubectl -n "$ns" rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
  say "router $arm in $ns: $(kubectl -n "$ns" get pods -o wide --no-headers | awk '/^router-epp/ && $3 == "Running" {print $1" on "$7}' | paste -sd' ')"
}

client_yaml() {  # namespace; also printed by `run.sh client-yaml NS` for the CI admission check
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: race-client
  namespace: $1
  labels: {app: race-client}
spec:
  restartPolicy: Never
  # Not on the model node: its CPU would be measured as engine time.
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector: {matchLabels: {app: $APP}}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: client
      image: $LOADGEN_IMAGE
      command: ["bash", "-c"]
      args:
        - pip install -q --disable-pip-version-check --no-cache-dir --target /deps aiohttp==3.14.5 >&2 && exec python3 /app/client.py
      env:
        - {name: "HOME", value: "/tmp"}
        - {name: "PYTHONPATH", value: "/deps"}
        - {name: "URL", value: "http://router-epp:8081/v1/completions"}
        - {name: "MODEL", value: "$MODEL"}
        - {name: "PROMPT", value: "The keep-alive race, one short prompt."}
        - {name: "N", value: "$N"}
        - {name: "GAP_MIN", value: "$GAP_MIN"}
        - {name: "GAP_MAX", value: "$GAP_MAX"}
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {memory: 256Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: app, mountPath: /app}
        - {name: deps, mountPath: /deps}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: app
      configMap: {name: race-client}
    - {name: deps, emptyDir: {}}
    - {name: tmp, emptyDir: {}}
YAML
}

client_up() {  # namespace
  local ns=$1
  kubectl -n "$ns" create configmap race-client --from-file=../client.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" delete pod race-client --ignore-not-found --wait >/dev/null
  client_yaml "$ns" | kubectl apply -f - >/dev/null
}

phase=${1:?phase: backend | arms | report | clean | client-yaml}
case "$phase" in
client-yaml)
  client_yaml "${2:?namespace}"
  ;;
backend)
  for a in "${ARMS[@]}"; do sed "s/__NS__/race-$a/g" model.yaml | kubectl apply -f - >/dev/null; done
  t0=$SECONDS
  until [ "$(ready race-chart)" = 1 ] && [ "$(ready race-idle)" = 1 ]; do
    [ $((SECONDS - t0)) -lt 1200 ] || { echo "not Ready after 20 min (stop condition of live-a026.md)"; kubectl get pods -A -l "app=$APP" -o wide; exit 1; }
    echo "$(ts) $((SECONDS - t0)) s: $(kubectl get pods -A -l "app=$APP" -o wide --no-headers | awk '{print $1"/"$2" "$3" "$4" "$8}' | paste -sd' ')"
    sleep 15
  done
  say "qwen-race: 1 replica Ready in race-chart and race-idle after $((SECONDS - t0)) s"
  for a in "${ARMS[@]}"; do
    p=$(kubectl -n "race-$a" get pods -l "app=$APP" -o name | head -1); n=$(kubectl -n "race-$a" get "$p" -o jsonpath='{.spec.nodeName}')
    say "race-$a $p node $n $(kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone} {.metadata.labels.node\.kubernetes\.io/instance-type} {.metadata.labels.karpenter\.sh/capacity-type}') cpu: $(kubectl -n "race-$a" exec "$p" -- sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    say "race-$a keep-alive: $(kubectl -n "race-$a" get "$p" -o jsonpath='{.spec.containers[0].env[?(@.name=="VLLM_HTTP_TIMEOUT_KEEP_ALIVE")].value}') s"
  done
  ;;
arms)
  [ "$(git -C "${ROUTER_SRC:?ROUTER_SRC: llm-d-router checkout}" rev-parse HEAD)" = "$ROUTER_MAIN_COMMIT" ] || { echo "ROUTER_SRC is not at $ROUTER_MAIN_COMMIT"; exit 1; }
  helm dependency build --skip-refresh "$ROUTER_SRC/config/charts/llm-d-router-standalone" >/dev/null
  for a in "${ARMS[@]}"; do router_up "race-$a" "$a"; done
  sleep 15  # each EPP discovers its pod and scrapes its metrics at least once
  for a in "${ARMS[@]}"; do client_up "race-$a"; done
  say "clients started: $N requests each, gap [$GAP_MIN, $GAP_MAX] s (about $((N * 5 / 60)) min)"
  t0=$SECONDS
  while :; do
    done_all=1 line=""
    for a in "${ARMS[@]}"; do
      ph=$(kubectl -n "race-$a" get pod race-client -o jsonpath='{.status.phase}')
      line+=" $a: $ph $(kubectl -n "race-$a" logs race-client 2>/dev/null | grep -c '^{' || true)/$N"
      [[ "$ph" =~ ^(Succeeded|Failed)$ ]] || done_all=0
    done
    echo "$(ts)$line"
    [ "$done_all" = 1 ] && break
    [ $((SECONDS - t0)) -lt 2400 ] || { echo "clients timed out"; exit 1; }
    sleep 30
  done
  for a in "${ARMS[@]}"; do
    kubectl -n "race-$a" logs race-client | grep '^{' > "results/eks-$a.jsonl" || true
    kubectl -n "race-$a" logs deploy/router-epp -c envoy-proxy --tail=-1 | grep '^{' > "results/eks-$a.envoy.log" || true
    kubectl -n "race-$a" logs deploy/router-epp --all-containers --prefix --tail=-1 > "results/eks-$a.router.log" 2>&1 || true
  done
  "$PY" ../report.py results/eks-chart.jsonl results/eks-idle.jsonl | tee results/report.txt | tee -a "$LOG"
  ;;
report)
  "$PY" ../report.py results/eks-*.jsonl | tee results/report.txt
  ;;
clean)
  for a in "${ARMS[@]}"; do
    helm uninstall router -n "race-$a" --wait >/dev/null 2>&1 || true
    kubectl delete namespace "race-$a" --ignore-not-found --wait
  done
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
