#!/usr/bin/env bash
# SLO under a public Azure LLM trace, on kind, CPU only, zero cloud cost.
# Protocol, rules and hypotheses: README.md (written before any run).
# Reuses the pinned set-up of ../prefix-routing (versions.env, Service,
# router values, Envoy idle timeout); the vLLM replicas keep the default KV
# cache (no --num-gpu-blocks-override: this experiment is not about eviction).
# Phases, one per command:
#   bash run.sh trace                  download both CSVs, check SHA-256, build the windows
#   bash run.sh up                     kind cluster (model cache mounted), namespace
#   bash run.sh backend                2 vLLM CPU replicas
#   bash run.sh calibrate TRACE        T and P (closed loop), then capacity C (Poisson ladder)
#   bash run.sh arm ARM REP TRACE      ARM = service | router; replay at 0.6 x C
#   bash run.sh report                 tables of every result in results/
#   bash run.sh down                   delete the kind cluster
# Needs: docker, kind, kubectl, helm 3, python3, curl, sha256sum. The image
# loaded as vllm-cpu-ci:pinned and the model in $HF_CACHE (CI does both).
set -euo pipefail
cd "$(dirname "$0")"
PR=../prefix-routing
. "$PR/versions.env"
. "$PR/envoy-idle.sh"
CLUSTER=trace-replay
mkdir -p results
phase=${1:?phase: trace | up | backend | calibrate | arm | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

# Fixed in README.md; changing one is an amendment.
LOAD_FACTOR=0.6          # mean offered rate = 0.6 x C
CALIB_LOW_N=40           # closed-loop requests for T and P
LADDER="0.25 0.5 1 2 4 8 16"
LADDER_S=60
SEED=20261126

declare -A SHA=(
  [conv]=2f1e5b666d4e3055fdbba98598ce2ec307767b9064e03e2fa46676dbcc7d0bf8
  [code]=54e9a6d2a4bd06ba1e060304b900abbc74cbea53de96506e60fe5bb4f2277fb6
)
BASE=https://raw.githubusercontent.com/Azure/AzurePublicDataset/master/data

# run_pod NAME OUT ARGS...: replay.py in a pod, its output to OUT; files from
# results/pod-input/ are mounted at /in.
run_pod() {
  local name=$1 out=$2; shift 2
  k create configmap "$name-in" --from-file=results/pod-input/ --from-file=replay.py \
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
  grep '"summary"' "$out" | python3 -c 'import json,sys; s=json.loads(sys.stdin.read())["summary"]; s.pop("meta",None); print(json.dumps(s))' | tee -a "$LOG"
}

reset_backend() {
  for p in $(k get pods -l app=model -o name); do
    k exec "$p" -- python3 -c 'import urllib.request as u; r=u.urlopen(u.Request("http://127.0.0.1:8000/reset_prefix_cache", method="POST"), timeout=30); print(r.status)' \
      | sed "s|^|reset_prefix_cache $p: HTTP |" | tee -a "$LOG"
  done
}

case "$phase" in
trace)
  for t in conv code; do
    f="results/$t.csv"
    [ -s "$f" ] || curl -fsSL --retry 3 -o "$f" "$BASE/AzureLLMInferenceTrace_$t.csv"
    echo "${SHA[$t]}  $f" | sha256sum -c - | tee -a "$LOG"
    say "trace $t: $(python3 trace.py stats "$f")"
    say "window $t: $(python3 trace.py window "$f" "results/window-$t.json")"
  done
  ;;
up)
  HF_CACHE=${HF_CACHE:-$PWD/results/hf-cache}; mkdir -p "$HF_CACHE"
  cat > results/kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $HF_CACHE
        containerPath: /hf-cache
EOF
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config results/kind.yaml --wait 120s | tee -a "$LOG"
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  say "kind $(kind version); kubernetes $(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
  say "cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1), $(nproc) cpus, $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k apply -f "$PR/manifests/service.yaml" >/dev/null
  ;;
backend)
  # Same StatefulSet as prefix-routing, default KV cache (1 GiB per replica).
  sed -e "s|__MODEL__|$MODEL|" -e "s|__MODEL_REVISION__|$MODEL_REVISION|" -e "s|__KEEPALIVE__|5|" \
      -e "s| --num-gpu-blocks-override 136||" "$PR/manifests/vllm.yaml" | k apply -f - >/dev/null
  t0=$SECONDS
  until [ "$(k get statefulset model -o jsonpath='{.status.readyReplicas}')" = 2 ]; do
    [ $((SECONDS - t0)) -lt 900 ] || { k logs -l app=model --tail=50 || true; exit 1; }
    echo "$((SECONDS - t0)) s: $(k get pods -l app=model --no-headers | awk '{print $1" "$2" "$3}' | paste -sd' ')"
    sleep 15
  done
  say "vllm $VLLM_CPU_VERSION: 2 replicas Ready after $((SECONDS - t0)) s"
  k logs model-0 | grep -iE 'bound to cores|num_gpu_blocks|KV cache|max_model_len' | head -6 | tee -a "$LOG" || true
  ;;
calibrate)
  t=${2:?trace: conv | code}
  rm -rf results/pod-input; mkdir -p results/pod-input
  python3 trace.py lengths "results/window-$t.json" 400 "$SEED" results/pod-input/lengths.json >/dev/null
  reset_backend
  # 1. T and P: one request at a time through the Service (README: SLO).
  run_pod calib "results/calib-$t-low.jsonl" --arm calib-low --url http://model:8000 --model "$MODEL" \
    --lengths /in/lengths.json --closed "$CALIB_LOW_N"
  read -r T P < <(python3 - "results/calib-$t-low.jsonl" <<'PY'
import json, math, sys
s = next(json.loads(l)["summary"] for l in open(sys.argv[1]) if '"summary"' in l)
print(math.ceil(2 * s["ttft_p95"] * 10) / 10, math.ceil(2 * s["tpot_p95"] * 100) / 100)
PY
)
  say "calibrate $t: T = $T s (2 x TTFT p95 one at a time), P = $P s (2 x TPOT p95)"
  # 2. C: highest Poisson rate of the ladder whose TTFT p95 <= T and TPOT p95 <= P,
  # then one midpoint between the last pass and the first fail.
  pass=0; fail=
  for r in $LADDER; do
    reset_backend
    run_pod calib "results/calib-$t-rate-$r.jsonl" --arm calib-rate --url http://model:8000 --model "$MODEL" \
      --lengths /in/lengths.json --poisson "$r" --duration "$LADDER_S" --ttft-slo "$T" --tpot-slo "$P" --seed "$SEED"
    if python3 - "results/calib-$t-rate-$r.jsonl" "$T" "$P" <<'PY'
import json, sys
s = next(json.loads(l)["summary"] for l in open(sys.argv[1]) if '"summary"' in l)
ok = s["failed"] == 0 and s["ttft_p95"] <= float(sys.argv[2]) and (s["tpot_p95"] is None or s["tpot_p95"] <= float(sys.argv[3]))
sys.exit(0 if ok else 1)
PY
    then pass=$r; else fail=$r; break; fi
  done
  [ "$pass" != 0 ] || { say "calibrate $t: even ${LADDER%% *} req/s breaks the SLO; stop"; exit 1; }
  if [ -n "$fail" ]; then
    mid=$(python3 -c "print(round(($pass + $fail) / 2, 3))")
    reset_backend
    run_pod calib "results/calib-$t-rate-$mid.jsonl" --arm calib-rate --url http://model:8000 --model "$MODEL" \
      --lengths /in/lengths.json --poisson "$mid" --duration "$LADDER_S" --ttft-slo "$T" --tpot-slo "$P" --seed "$SEED"
    python3 - "results/calib-$t-rate-$mid.jsonl" "$T" "$P" <<'PY' && pass=$mid
import json, sys
s = next(json.loads(l)["summary"] for l in open(sys.argv[1]) if '"summary"' in l)
ok = s["failed"] == 0 and s["ttft_p95"] <= float(sys.argv[2]) and (s["tpot_p95"] is None or s["tpot_p95"] <= float(sys.argv[3]))
sys.exit(0 if ok else 1)
PY
  fi
  rate=$(python3 -c "print(round($LOAD_FACTOR * $pass, 4))")
  printf '{"trace": "%s", "T": %s, "P": %s, "C": %s, "rate": %s}\n' "$t" "$T" "$P" "$pass" "$rate" > "results/calib-$t.json"
  say "calibrate $t: C = $pass req/s; replay at $rate req/s mean"
  python3 trace.py thin "results/window-$t.json" "$rate" "$SEED" "results/schedule-$t.json" | tee -a "$LOG"
  ;;
arm)
  arm=${2:?arm: service | router}; rep=${3:-1}; t=${4:?trace: conv | code}
  read -r T P < <(python3 -c "import json; c=json.load(open('results/calib-$t.json')); print(c['T'], c['P'])")
  rm -rf results/pod-input; mkdir -p results/pod-input
  cp "results/schedule-$t.json" results/pod-input/schedule.json
  reset_backend
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  case "$arm" in
    service) url="http://model:8000" ;;
    router)
      # The chart's default configuration at v1.0.0 (prefix-routing arm "prefix").
      helm upgrade -i router "$ROUTER_CHART" --version "$ROUTER_VERSION" -n "$NS" --wait --timeout 300s \
        -f "$PR/values/router.yaml" -f "$PR/values/prefix.yaml" \
        --set router.epp.image.tag="$EPP_IMAGE_TAG" --set router.proxy.image="$ENVOY_IMAGE" >/dev/null
      envoy_upstream_idle "$NS" restart | tee -a "$LOG"
      k rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
      sleep 15
      url="http://router-epp:8081" ;;
    *) echo "unknown arm $arm"; exit 1 ;;
  esac
  say "arm $arm rep $rep trace $t via $url (T $T s, P $P s)"
  run_pod replay "results/$t-$arm-$rep.jsonl" --arm "$arm" --url "$url" --model "$MODEL" \
    --schedule /in/schedule.json --ttft-slo "$T" --tpot-slo "$P"
  if [ "$arm" = router ]; then k logs deploy/router-epp --all-containers --prefix --tail=-1 > "results/$t-$arm-$rep.router.log" 2>&1 || true; fi
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  ;;
report)
  ls results/*-service-*.jsonl results/*-router-*.jsonl >/dev/null 2>&1 || { echo "no results yet"; exit 0; }
  python3 report.py results | tee results/report.md
  ;;
down)
  kind delete cluster --name "$CLUSTER"
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
