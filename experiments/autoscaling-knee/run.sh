#!/usr/bin/env bash
# Autoscaling at the measured capacity: KEDA on vLLM's requests in flight,
# threshold at the knee (D-0181) or at Little's law, against a pool sized
# for the peak, on kind. Protocol and hypotheses: README.md.
# Reuses ../finops-guardrail (kind, CRDs, vLLM StatefulSet, router values),
# ../trace-replay (trace window, replay.py) and ../prefix-routing (pins).
# Phases, one per command:
#   bash run.sh up                 trace pinned, kind, the two CRDs
#   bash run.sh backend BACKEND    BACKEND = vllm (load the image first) | sim
#   bash run.sh monitoring         Prometheus and KEDA, pinned
#   bash run.sh schedule           the step load and the lengths for L
#   bash run.sh little             L by the README rule (vllm)
#   bash run.sh arm ARM NAME       ARM = static2 | knee | little
#   bash run.sh report             tables and H1-H4 of every result in results/
#   bash run.sh down               delete the kind cluster
set -euo pipefail
cd "$(dirname "$0")"
TR=../trace-replay
FG=../finops-guardrail
PR=../prefix-routing
. "$PR/versions.env"
. "$PR/envoy-idle.sh"
CLUSTER=trace-replay
mkdir -p results
phase=${1:?phase: up | backend | monitoring | schedule | little | arm | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

# Fixed in README.md; changing one is an amendment.
T=0.9; P=0.13                 # SLO measured on Intel Xeon 6975P-C (D-0181)
KNEE=4                        # requests in flight per replica declared in D-0181
LITTLE_RATE=0.35; LITTLE_S=180
SEED=20261126
# KEDA 2.21.0, the pins of vllm-coldstart-operator's CI at v0.18.0.
KEDA_CHART_URL=https://kedacore.github.io/charts/keda-2.21.0.tgz
KEDA_CHART_SHA256=a7da56bf41a33dad9d2fc82a6fdecee552fff947d80bf1e1dbcf4db0f9e26dee
KEDA_IMAGE_KEDA=2.21.0@sha256:81fe6547ce8d1cc29273f887b76507e9b853e5bc1f875ec23fe60061a38ed809
KEDA_IMAGE_METRICS=2.21.0@sha256:255375037fe592732eeb554743aae360c2da88cf0b9b1258d0a987ef885f0881
KEDA_IMAGE_WEBHOOKS=2.21.0@sha256:e1969628cca6123e32eea13c47c75817091af2657fa68d9d0d58a8620d1b75b1

kind_of() { k get statefulset model >/dev/null 2>&1 && echo StatefulSet || echo Deployment; }
restarts() { k get pods -l app=model -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s += $1} END {print s + 0}'; }
# promq QUERY: one instant value from Prometheus, through the API server.
promq() {
  local q; q=$(python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/query?query=$q" |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")'
}
# replicas N: scale the model to N and wait until exactly N pods exist, all Ready.
replicas() {
  local kind; kind=$(kind_of)
  k scale "$kind/model" --replicas="$1" >/dev/null
  local t0=$SECONDS
  until [ "$(k get pods -l app=model --no-headers 2>/dev/null | wc -l)" = "$1" ] &&
        [ "$(k get "$kind" model -o jsonpath='{.status.readyReplicas}')" = "$1" ]; do
    [ $((SECONDS - t0)) -lt 900 ] || { k get pods -l app=model; exit 1; }
    sleep 5
  done
  say "model: $1 replica(s) Ready after $((SECONDS - t0)) s"
}
router_up() {
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  helm upgrade -i router "$ROUTER_CHART" --version "$ROUTER_VERSION" -n "$NS" --wait --timeout 300s \
    -f "$PR/values/router.yaml" -f "$FG/values/pool.yaml" \
    --set router.epp.image.tag="$EPP_IMAGE_TAG" --set router.proxy.image="$ENVOY_IMAGE" >/dev/null
  envoy_upstream_idle "$NS" restart | tee -a "$LOG"
  k rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
  sleep 15
}
# replay NAME OUT ARGS...: ../trace-replay/replay.py in a pod, inputs from results/in/.
replay() {
  local name=$1 out=$2; shift 2
  k create configmap "$name-in" --from-file=results/in/ --from-file="$TR/replay.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k delete pod "$name" --ignore-not-found --wait >/dev/null
  local args; args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /in/replay.py "$@")
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  containers:
    - name: replay
      image: $LOADGEN_IMAGE
      command: ["python3"]
      args: $args
      resources:
        requests: {cpu: 200m, memory: 128Mi}
      volumeMounts:
        - {name: in, mountPath: /in}
  volumes:
    - name: in
      configMap: {name: $name-in}
YAML
  local t0=$SECONDS
  until [[ "$(k get pod "$name" -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt 3600 ] || { echo "$name timed out"; exit 1; }
    sleep 5
  done
  k logs "$name" > "$out"
  [ "$(k get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || { tail -20 "$out"; exit 1; }
}

case "$phase" in
up)
  bash "$FG/run.sh" up
  ;;
backend)
  bash "$FG/run.sh" backend "${2:?backend: vllm | sim}"
  ;;
monitoring)
  kubectl apply -f manifests/prometheus.yaml >/dev/null
  kubectl -n monitoring rollout status deploy/prometheus --timeout=300s | tee -a "$LOG"
  curl -fsSL --retry 3 -o results/keda.tgz "$KEDA_CHART_URL"
  echo "$KEDA_CHART_SHA256  results/keda.tgz" | sha256sum -c - | tee -a "$LOG"
  helm upgrade -i keda results/keda.tgz -n keda --create-namespace --wait --timeout 5m \
    --set image.keda.tag="$KEDA_IMAGE_KEDA" --set image.metricsApiServer.tag="$KEDA_IMAGE_METRICS" \
    --set image.webhooks.tag="$KEDA_IMAGE_WEBHOOKS" >/dev/null
  for d in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
    kubectl -n keda rollout status "deploy/$d" --timeout=2m >/dev/null
  done
  got=$(kubectl -n keda get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort)
  want=$(printf '%s\n' "ghcr.io/kedacore/keda:$KEDA_IMAGE_KEDA" "ghcr.io/kedacore/keda-metrics-apiserver:$KEDA_IMAGE_METRICS" \
    "ghcr.io/kedacore/keda-admission-webhooks:$KEDA_IMAGE_WEBHOOKS" | sort)
  [ "$got" = "$want" ] || { echo "KEDA runs [$got], want [$want]"; exit 1; }
  t0=$SECONDS
  until [ "$(promq 'count(up{job="model"} == 1)')" != nan ]; do
    [ $((SECONDS - t0)) -lt 120 ] || { echo "Prometheus scrapes no model pod"; exit 1; }
    sleep 5
  done
  say "monitoring: Prometheus scrapes $(promq 'count(up{job="model"} == 1)') model pod(s); KEDA 2.21.0 on the pinned images"
  ;;
schedule)
  rm -rf results/in; mkdir -p results/in
  python3 profile.py "$TR/results/window-conv.json" results/in/schedule.json | tee -a "$LOG"
  python3 "$TR/trace.py" lengths "$TR/results/window-conv.json" 400 "$SEED" results/in/lengths.json >/dev/null
  ;;
little)
  # README "Rule for L": 1 replica, the router, Poisson at 0.35 req/s for
  # 180 s; L = mean of running + waiting over the replay, from Prometheus.
  replicas 1
  router_up
  replay little "results/little.jsonl" --arm little-calib --url http://router-epp:8081 --model "${MODEL_NAME:-$MODEL}" \
    --lengths /in/lengths.json --poisson "$LITTLE_RATE" --duration "$LITTLE_S" --ttft-slo "$T" --tpot-slo "$P" --seed "$SEED"
  sleep 10   # one more scrape after the last response
  L=$(promq "avg_over_time((sum(vllm:num_requests_running) + sum(vllm:num_requests_waiting))[$((LITTLE_S + 10))s:5s])")
  L=$(python3 -c "import math,sys; v=float(sys.argv[1]); assert not math.isnan(v) and v > 0, v; print(round(v, 2))" "$L")
  printf '{"L": %s, "rate": %s, "duration_s": %s}\n' "$L" "$LITTLE_RATE" "$LITTLE_S" > results/little.json
  grep '"summary"' results/little.jsonl | tee -a "$LOG" >/dev/null
  say "little: L = $L requests in flight per replica at $LITTLE_RATE req/s"
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  ;;
arm)
  arm=${2:?arm: static2 | knee | little}; name=${3:?name}
  kind=$(kind_of)
  case "$arm" in
    static2) thr=; replicas 2 ;;
    knee) thr=${THRESHOLD:-$KNEE}; replicas 1 ;;
    little) thr=${THRESHOLD:-$(python3 -c "import json; print(json.load(open('results/little.json'))['L'])")}; replicas 1 ;;
    *) echo "unknown arm $arm"; exit 1 ;;
  esac
  router_up
  if [ -n "$thr" ]; then
    sed -e "s|__KIND__|$kind|" -e "s|__THRESHOLD__|$thr|" manifests/scaledobject.yaml > "results/$name.scaledobject.yaml"
    k apply -f "results/$name.scaledobject.yaml" >/dev/null
    t0=$SECONDS
    until [ "$(k get hpa keda-hpa-model -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null)" = True ]; do
      [ $((SECONDS - t0)) -lt 180 ] || { k describe hpa keda-hpa-model || true; k get scaledobject model -o yaml || true; exit 1; }
      sleep 5
    done
  fi
  r0=$(restarts)
  # Sampler: epoch, model pods existing, Ready, HPA desired, HPA metric.
  (
    while :; do
      ex=$(k get pods -l app=model --no-headers 2>/dev/null | wc -l)
      rd=$(k get "$kind" model -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      hp=$(k get hpa keda-hpa-model -o jsonpath='{.status.desiredReplicas} {.status.currentMetrics[0].external.current.averageValue}' 2>/dev/null || true)
      echo "$(date +%s) $ex ${rd:-0} ${hp:-- -}"
      sleep 5
    done
  ) > "results/$name.samples" &
  sampler=$!
  say "arm $arm ($name): T $T s, P $P s, threshold ${thr:-none}, $(k get pods -l app=model --no-headers | wc -l) replica(s) at start"
  replay replay "results/$name.jsonl" --arm "$arm" --url http://router-epp:8081 --model "${MODEL_NAME:-$MODEL}" \
    --schedule /in/schedule.json --ttft-slo "$T" --tpot-slo "$P"
  kill "$sampler" 2>/dev/null || true
  started=$(k get pod replay -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}')
  [ -z "$thr" ] || { k describe hpa keda-hpa-model > "results/$name.hpa.txt" 2>&1 || true; k delete scaledobject model --wait >/dev/null; }
  r1=$(restarts)
  [ $((r1 - r0)) -eq 0 ] || for pod in $(k get pods -l app=model -o jsonpath='{.items[*].metadata.name}'); do
    [ "$(k get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -gt 0 ] || continue
    k get pod "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' > "results/$name.$pod.last-state.json" || true
    k logs "$pod" --previous --tail=200 > "results/$name.$pod.prev.log" 2>&1 || true
  done
  k get events --sort-by=.lastTimestamp 2>/dev/null | grep -E 'model|keda' > "results/$name.events.txt" || true
  printf '{"name": "%s", "arm": "%s", "threshold": %s, "T": %s, "P": %s, "started": "%s", "restarts": %s}\n' \
    "$name" "$arm" "${thr:-null}" "$T" "$P" "$started" "$((r1 - r0))" > "results/$name.meta.json"
  python3 report.py --one "results/$name" | tee -a "$LOG"
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  ;;
report)
  ls results/*.meta.json >/dev/null 2>&1 || { echo "no results yet"; exit 0; }
  python3 report.py results | tee results/report.md
  ;;
down)
  kind delete cluster --name "$CLUSTER"
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
