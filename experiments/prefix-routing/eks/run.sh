#!/usr/bin/env bash
# Prefix-aware routing on EKS (protocol: ../EKS.md, written before the
# session). Runs from the operator's machine against the live cluster of
# docs/runbooks/live-a025.md (current kubectl context). One phase per command:
#   bash run.sh backend            VllmService qwen-prefix, 2 replicas in 2 zones; nodes, zones, CPU
#   bash run.sh arm ARM REP        one measured run; ARM = service | prefix | legacy | ea
#   bash run.sh all                every arm, 3 repetitions, order reversed each time (EKS.md)
#   bash run.sh report             table of every summary in results/
#   bash run.sh probe-router up    S3'': router + probe through it, on the game day model
#   bash run.sh probe-router down
#   bash run.sh clean              router, loadgen, namespace inference-bench
# Arms legacy and ea need ROUTER_SRC, a llm-d-router checkout at
# ROUTER_MAIN_COMMIT (chart from it; EPP image from upstream's per-commit build).
# Every wait prints one line per iteration (game day #1: a silent loop cost
# 28 minutes when the SSH session dropped).
set -euo pipefail
cd "$(dirname "$0")"
. ../versions.env
NS=inference-bench
SVC=qwen-prefix
CLIENT_LABEL=inference.michelecampi.dev/client
mkdir -p results
LOG=results/run.log
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

# Ready model pods only, never a terminating one.
pod_targets() {
  k get pods -l "app=$SVC" -o json | python3 -c '
import json, sys
ps = json.load(sys.stdin)["items"]
ok = [p["status"]["podIP"] + ":8000" for p in ps
      if not p["metadata"].get("deletionTimestamp")
      and any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))]
print(",".join(sorted(ok)))'
}

# Install the router in front of pods app=$1 in namespace $2, arm $3, and
# label its pod as a client of that VllmService (see router-eks.yaml).
router_up() {
  local app=$1 ns=$2 arm=$3
  local common=(-n "$ns" --wait --timeout 300s -f ../values/router.yaml -f router-eks.yaml -f "../values/$arm.yaml"
    --set "router.modelServers.matchLabels.app=$app")
  case "$arm" in
    prefix|random)
      helm upgrade -i router "$ROUTER_CHART" --version "$ROUTER_VERSION" "${common[@]}" \
        --set router.epp.image.tag="$EPP_IMAGE_TAG" --set router.proxy.image="$ENVOY_IMAGE" >/dev/null ;;
    legacy|ea)
      [ "$(git -C "${ROUTER_SRC:?ROUTER_SRC: llm-d-router checkout}" rev-parse HEAD)" = "$ROUTER_MAIN_COMMIT" ] || { echo "ROUTER_SRC is not at $ROUTER_MAIN_COMMIT"; exit 1; }
      local img=${ROUTER_MAIN_EPP_IMAGE_REMOTE%%:*} ref=${ROUTER_MAIN_EPP_IMAGE_REMOTE#*:}
      helm upgrade -i router "$ROUTER_SRC/config/charts/llm-d-router-standalone" "${common[@]}" \
        --set router.epp.image.registry="${img%/*}" --set router.epp.image.repository="${img##*/}" \
        --set router.epp.image.tag="$ref" --set router.proxy.image="$ROUTER_MAIN_ENVOY_IMAGE" >/dev/null ;;
    *) echo "unknown router arm $arm"; exit 1 ;;
  esac
  kubectl -n "$ns" patch deploy router-epp --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"$CLIENT_LABEL\":\"$app\"}}}}}" >/dev/null
  kubectl -n "$ns" rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
  say "router $arm in $ns: $(kubectl -n "$ns" get pods -o wide --no-headers | awk '/^router-epp/ && $3 == "Running" {print $1" on "$7}' | paste -sd' ')"
  sleep 15  # EPP discovers the pods and scrapes their metrics at least once
}

reset_caches() {
  for p in $(k get pods -l "app=$SVC" -o name); do
    k exec "$p" -- python3 -c 'import urllib.request as u; r=u.urlopen(u.Request("http://127.0.0.1:8000/reset_prefix_cache", method="POST"), timeout=30); print(r.status)' \
      | sed "s|^|reset_prefix_cache $p: HTTP |" | tee -a "$LOG"
  done
}

arm() {
  local arm=$1 rep=$2 url out
  out="results/eks-$arm-$rep.jsonl"
  reset_caches
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  if [ "$arm" = service ]; then url="http://$SVC:8000"; else router_up "$SVC" "$NS" "$arm"; url="http://router-epp:8081"; fi
  say "arm $arm rep $rep via $url, pods $(pod_targets)"
  k delete pod loadgen --ignore-not-found --wait >/dev/null
  local args
  args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /app/loadgen.py \
    --arm "$arm" --url "$url" --model "$MODEL" --pods "$(pod_targets)" --requests "${REQUESTS:-160}" --concurrency "${CONCURRENCY:-4}")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
  labels: {app: loadgen, $CLIENT_LABEL: $SVC}
spec:
  restartPolicy: Never
  # Not on a model node: its CPU would be measured as engine time.
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector: {matchLabels: {app: $SVC}}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: loadgen
      image: $LOADGEN_IMAGE
      command: ["python3"]
      args: $args
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {memory: 256Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: app, mountPath: /app}
  volumes:
    - name: app
      configMap: {name: loadgen}
EOF
  local t0=$SECONDS phase=""
  until [[ "$phase" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt 1800 ] || { echo "loadgen timed out"; exit 1; }
    sleep 10
    phase=$(k get pod loadgen -o jsonpath='{.status.phase}')
    echo "$(ts) arm $arm rep $rep: loadgen $phase, $(k logs loadgen 2>/dev/null | grep -c '"req"' || true) requests done"
  done
  k logs loadgen > "$out"
  [ "$phase" = Succeeded ] || { tail -20 "$out"; exit 1; }
  grep '"summary"' "$out" | tee -a "$LOG"
  if [ "$arm" != service ]; then
    k logs deploy/router-epp --all-containers --prefix --tail=-1 > "results/eks-$arm-$rep.router.log" 2>&1 || true
    helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  fi
}

phase=${1:?phase: backend | arm | all | report | probe-router | clean}
case "$phase" in
backend)
  kubectl apply -f model.yaml >/dev/null
  k create configmap loadgen --from-file=../loadgen.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  t0=$SECONDS
  until [ "$(k get vllmservice "$SVC" -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ] && [ "$(pod_targets | tr ',' '\n' | grep -c .)" = 2 ]; do
    [ $((SECONDS - t0)) -lt 1200 ] || { echo "not Ready after 20 min (stop condition of live-a025.md)"; k get pods -o wide; exit 1; }
    echo "$(ts) $((SECONDS - t0)) s: $(k get pods -l "app=$SVC" -o wide --no-headers | awk '{print $1" "$2" "$3" "$7}' | paste -sd' ')"
    sleep 15
  done
  say "qwen-prefix: 2 replicas Ready after $((SECONDS - t0)) s: $(pod_targets)"
  for p in $(k get pods -l "app=$SVC" -o name); do
    n=$(k get "$p" -o jsonpath='{.spec.nodeName}')
    say "$p node $n $(kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone} {.metadata.labels.node\.kubernetes\.io/instance-type} {.metadata.labels.karpenter\.sh/capacity-type}') cpu: $(k exec "$p" -- sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    k logs "$p" | grep -iE 'num_gpu_blocks|KV cache|prefix cach' | head -3 | tee -a "$LOG" || true
  done
  ;;
arm)
  arm "${2:?arm: service | prefix | legacy | ea}" "${3:-1}"
  ;;
all)
  # EKS.md: 3 repetitions, the order reversed on each one.
  order=(service prefix legacy ea)
  for rep in 1 2 3; do
    if [ "$rep" = 2 ]; then seq=(ea legacy prefix service); else seq=("${order[@]}"); fi
    for a in "${seq[@]}"; do arm "$a" "$rep"; done
  done
  python3 ../report.py results/eks-*.jsonl | tee results/report.md
  ;;
report)
  python3 ../report.py results/eks-*.jsonl | tee results/report.md
  ;;
probe-router)
  # S3'' observation O1 (EKS.md): the same probe as tests/gameday/probe.yaml,
  # through the router instead of the Service, on the game day model.
  GNS=inference-test GAPP=qwen-0-5b-cpu
  if [ "${2:?up | down}" = up ]; then
    router_up "$GAPP" "$GNS" prefix
    kubectl apply -f probe-router.yaml >/dev/null
    kubectl -n "$GNS" rollout status deploy/probe-router --timeout=180s | tee -a "$LOG"
  else
    kubectl -n "$GNS" logs deploy/probe-router --tail=-1 > results/probe-router.jsonl || true
    kubectl -n "$GNS" logs deploy/router-epp --all-containers --prefix --tail=-1 > results/probe-router.router.log 2>&1 || true
    kubectl delete -f probe-router.yaml --ignore-not-found >/dev/null
    helm uninstall router -n "$GNS" --wait >/dev/null 2>&1 || true
    say "probe-router: $(wc -l < results/probe-router.jsonl) lines saved"
  fi
  ;;
clean)
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found --wait
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
