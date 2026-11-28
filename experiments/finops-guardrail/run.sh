#!/usr/bin/env bash
# FinOps guardrail at the peak: llm-d-router v1.0.0 flow control with
# priority holdback against the same router with no policy, under the
# replayed Azure trace, on kind. Protocol and hypotheses: README.md.
# Reuses ../trace-replay (trace, cluster, vLLM replicas, calibration, replay)
# and ../prefix-routing (pins, router values, Envoy idle timeout).
# Phases, one per command:
#   bash run.sh up                trace pinned, kind, the two CRDs
#   bash run.sh backend BACKEND   BACKEND = vllm (load the image first) | sim
#   bash run.sh calibrate         T, P and C for conv with the step 7 code (vllm)
#   bash run.sh arm ARM NAME      ARM = nopolicy | guardrail; replay at 0.6 x C
#   bash run.sh report            tables and H1-H3 of every result in results/
#   bash run.sh down              delete the kind cluster
set -euo pipefail
cd "$(dirname "$0")"
TR=../trace-replay
PR=../prefix-routing
. "$PR/versions.env"
. "$PR/envoy-idle.sh"
CLUSTER=trace-replay   # the cluster ../trace-replay/run.sh creates
TRACE=conv
mkdir -p results
phase=${1:?phase: up | backend | calibrate | arm | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

# Fixed in README.md; changing one is an amendment.
TENANTS="premium=0.3,batch"
BATCH_TTFT_X=10
LOAD_X=1.5               # amendment 2: mean offered rate = 1.5 x C (step 7 replays 0.6 x C)
SEED=20261126            # the step 7 thinning seed
# CRDs from pinned files (read 2026-11-27): InferencePool from Gateway API
# Inference Extension v1.6.2 (the version llm-d-router v1.0.0's go.mod
# requires), InferenceObjective from llm-d-router v1.0.0.
GIE_CRD_URL=https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/v1-manifests.yaml
GIE_CRD_SHA256=f410dfca474608c02903087b47f1ac081706dfb6dfe7f83d00a7cc7e00c4ad0d
IO_CRD_URL=https://raw.githubusercontent.com/llm-d/llm-d-router/v1.0.0/config/crd/bases/llm-d.ai_inferenceobjectives.yaml
IO_CRD_SHA256=ff12ac55b79a8db719be4da2082b02cbf9b35e482cf20c040c9304f766beeaf4

restarts() { k get pods -l app=model -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s += $1} END {print s + 0}'; }
calib() { python3 -c "import json; c=json.load(open('$TR/results/calib-$TRACE.json')); print(c['$1'])"; }

# replay NAME OUT ARGS...: the step 7 replayer in a pod (as ../trace-replay).
replay() {
  local name=$1 out=$2; shift 2
  k create configmap "$name-in" --from-file="$TR/results/schedule-$TRACE.json" --from-file="$TR/replay.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k delete pod "$name" --ignore-not-found --wait >/dev/null
  local args; args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /in/replay.py "$@")
  k apply -f - >/dev/null <<EOF
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
EOF
  local t0=$SECONDS
  until [[ "$(k get pod "$name" -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt 3600 ] || { echo "$name timed out"; exit 1; }
    sleep 10
  done
  k logs "$name" > "$out"
  [ "$(k get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || { tail -20 "$out"; exit 1; }
}

case "$phase" in
up)
  bash "$TR/run.sh" trace
  bash "$TR/run.sh" up
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  for c in "gie $GIE_CRD_URL $GIE_CRD_SHA256" "io $IO_CRD_URL $IO_CRD_SHA256"; do
    read -r n u h <<<"$c"
    [ -s "results/crd-$n.yaml" ] || curl -fsSL --retry 3 -o "results/crd-$n.yaml" "$u"
    echo "$h  results/crd-$n.yaml" | sha256sum -c - | tee -a "$LOG"
    kubectl apply --server-side -f "results/crd-$n.yaml" >/dev/null
  done
  kubectl wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io crd/inferenceobjectives.llm-d.ai --timeout=60s >/dev/null
  say "up: CRDs InferencePool (GIE v1.6.2) and InferenceObjective (llm-d-router v1.0.0)"
  ;;
backend)
  backend=${2:?backend: vllm | sim}
  if [ "$backend" = sim ]; then
    # Simulator standing in for vLLM (mechanics only): 2 replicas that take
    # 2 requests at a time and decode slowly, so that a burst queues.
    sed -e "s|SIM_IMAGE|$SIM_IMAGE|" -e 's|replicas: 4|replicas: 2|' \
        -e '/--max-num-seqs/{n;s|"4"|"2"|}' -e '/--inter-token-latency/{n;s|5ms|40ms|}' \
        "$PR/manifests/sim.yaml" | k apply -f - >/dev/null
    k rollout status deploy/model --timeout=300s | tee -a "$LOG"
  else
    bash "$TR/run.sh" backend
  fi
  say "backend $backend ready"
  ;;
calibrate)
  bash "$TR/run.sh" calibrate "$TRACE"
  # capacity-knee amendment 1: FIXED_SLO="T P C" fixes the SLO and the load;
  # the measured values are kept for the record.
  if [ -n "${FIXED_SLO:-}" ]; then
    cp "$TR/results/calib-$TRACE.json" "$TR/results/calib-$TRACE.measured.json"
    read -r fT fP fC <<<"$FIXED_SLO"
    python3 - "$TR/results/calib-$TRACE.json" "$fT" "$fP" "$fC" <<'PY1'
import json, sys
c = json.load(open(sys.argv[1])); c.update(T=float(sys.argv[2]), P=float(sys.argv[3]), C=float(sys.argv[4]), fixed=True)
json.dump(c, open(sys.argv[1], "w"))
PY1
    say "calibrate: measured $(cat "$TR/results/calib-$TRACE.measured.json"); fixed T $fT s, P $fP s, C $fC req/s (capacity-knee amendment 1)"
  fi
  # Amendment 2: the same window, thinned again from the full window to
  # LOAD_X x C with the same seed (time is compressed if LOAD_X x C is above
  # the window's mean rate, as in step 7 amendment 1).
  C=$(calib C)
  rate=$(python3 -c "print(round($LOAD_X * $C, 4))")
  python3 "$TR/trace.py" thin "$TR/results/window-$TRACE.json" "$rate" "$SEED" "$TR/results/schedule-$TRACE.json" | tee -a "$LOG"
  python3 - "$TR/results/calib-$TRACE.json" "$rate" "$LOAD_X" <<'PY2'
import json, sys
c = json.load(open(sys.argv[1])); c.update(rate=float(sys.argv[2]), load_x=float(sys.argv[3]))
json.dump(c, open(sys.argv[1], "w"))
PY2
  say "calibrate: replay at $LOAD_X x C = $rate req/s mean (amendment 2)"
  ;;
arm)
  arm=${2:?arm: nopolicy | guardrail}; name=${3:?name}; ttl=
  MAX_CONC=${MAX_CONC:-1}   # requests per replica (experiments/capacity-knee)
  r0=$(restarts)
  T=$(calib T); P=$(calib P)
  model=${MODEL_NAME:-$MODEL}
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  k delete inferenceobjective --all --ignore-not-found >/dev/null
  vals=(-f "$PR/values/router.yaml" -f values/pool.yaml)
  if [ "$arm" = guardrail ]; then
    ttl=$(python3 -c "import math; print(str(math.ceil($BATCH_TTFT_X * $T)) + 's')")
    sed -e "s|__BATCH_TTL__|$ttl|" -e "s|__MAX_CONC__|$MAX_CONC|" values/guardrail.yaml > results/guardrail-values.yaml
    vals+=(-f results/guardrail-values.yaml)
    k apply -f manifests/objectives.yaml >/dev/null
  elif [ "$arm" != nopolicy ]; then
    echo "unknown arm $arm"; exit 1
  fi
  helm upgrade -i router "$ROUTER_CHART" --version "$ROUTER_VERSION" -n "$NS" --wait --timeout 300s "${vals[@]}" \
    --set router.epp.image.tag="$EPP_IMAGE_TAG" --set router.proxy.image="$ENVOY_IMAGE" >/dev/null
  helm get manifest router -n "$NS" > "results/$name.manifest.yaml"
  envoy_upstream_idle "$NS" restart | tee -a "$LOG"
  k rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
  sleep 15  # EPP discovers the pods and the objectives, and scrapes the pods once
  k get inferencepool,inferenceobjective -o wide 2>&1 | tee -a "$LOG" || true
  say "arm $arm ($name): T $T s, P $P s, tenants $TENANTS${ttl:+, batch TTL $ttl, maxConcurrency $MAX_CONC}"
  replay replay "results/$name.jsonl" --arm "$arm" --url http://router-epp:8081 --model "$model" \
    --schedule "/in/schedule-$TRACE.json" --ttft-slo "$T" --tpot-slo "$P" --tenants "$TENANTS"
  k logs deploy/router-epp -c epp --tail=-1 > "results/$name.epp.log" 2>&1 || true
  # Model container restarts during this rep (capacity-knee H4): the
  # previous container's log, exit code and reason, per restarted pod.
  r1=$(restarts)
  [ $((r1 - r0)) -eq 0 ] || for pod in $(k get pods -l app=model -o jsonpath='{.items[*].metadata.name}'); do
    [ "$(k get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -gt 0 ] || continue
    k get pod "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' > "results/$name.$pod.last-state.json" || true
    k logs "$pod" --previous --tail=200 > "results/$name.$pod.prev.log" 2>&1 || true
  done
  printf '{"name": "%s", "arm": "%s", "T": %s, "P": %s, "batch_ttft_x": %s, "tenants": "%s", "max_conc": %s, "restarts": %s}\n' \
    "$name" "$arm" "$T" "$P" "$BATCH_TTFT_X" "$TENANTS" "$([ "$arm" = guardrail ] && echo "$MAX_CONC" || echo null)" "$((r1 - r0))" > "results/$name.meta.json"
  python3 report.py --one "results/$name.jsonl" "results/$name.meta.json" | tee -a "$LOG"
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  ;;
report)
  ls results/*.meta.json >/dev/null 2>&1 || { echo "no results yet"; exit 0; }
  python3 report.py ${KNEE:+--knee} results | tee results/report.md
  ;;
down)
  kind delete cluster --name "$CLUSTER"
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
