#!/usr/bin/env bash
# Canary with automatic rollback on the SLO, on kind, zero cloud cost.
# Protocol, rules and hypotheses: README.md (written before any run); tool
# choice: docs/adr/0003-canary-rollout-tool.md.
# Reuses ../prefix-routing/versions.env (pins), ../trace-replay (trace,
# calibration, replay.py) and the same Service.
# Phases, one per command:
#   bash run.sh up BACKEND                  kind (static CPU manager), Argo Rollouts, Prometheus, analysis
#   bash run.sh backend KIND BACKEND        fresh v1 workload, 2 pods serving (KIND = rollout | deployment)
#   bash run.sh calibrate                   T, P, C on v1 (trace-replay rules), then tb
#   bash run.sh tb                          T_b: the analysis bucket, from Prometheus
#   bash run.sh rep NAME KIND VERSION BACKEND
#                                           one replay; VERSION = none (baseline) | v2-good | v2-bad,
#                                           applied TRIGGER_S into the replay
#   bash run.sh report                      tables and H1-H4
#   bash run.sh down                        delete the kind cluster
# BACKEND = vllm | stub (CI smoke only). Needs: docker, kind, kubectl,
# python3, curl, sha256sum.
set -euo pipefail
cd "$(dirname "$0")"
TR=../trace-replay
. ../prefix-routing/versions.env
CLUSTER=canary-rollback
mkdir -p results
phase=${1:?phase: up | backend | calibrate | tb | rep | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }

# Fixed in README.md; changing one is an amendment.
TRIGGER_S=${TRIGGER_S:-240}   # rollout started this far into the replay (smoke: shorter)
TRACE=conv
ROLLOUTS_VERSION=v1.10.2
ROLLOUTS_INSTALL_SHA256=b8280994791eaee7eb91c8b84450efcc6e0292fca5aafc18c1b0ebc5d18dbefe
ROLLOUTS_IMAGE=quay.io/argoproj/argo-rollouts:$ROLLOUTS_VERSION
PROMETHEUS_IMAGE=quay.io/prometheus/prometheus:v3.16.0
# 1-core replicas have about half the capacity of step 7's 2-core ones, so
# the ladder starts lower; the rule (highest passing rate, one midpoint) is
# the same.
export LADDER="0.0625 0.125 0.25 0.5 1 2 4"

wait_serving() {  # wait_serving N VERSION TIMEOUT_S
  local n=$1 v=$2 t0=$SECONDS
  until [ "$(k get pods -l app=model,version="$v" -o json | python3 -c '
import json,sys
print(sum(1 for p in json.load(sys.stdin)["items"] if "deletionTimestamp" not in p["metadata"]
          and any(c["type"]=="Ready" and c["status"]=="True" for c in p["status"].get("conditions",[]))))')" -ge "$n" ]; do
    [ $((SECONDS - t0)) -lt "$3" ] || { k get pods -l app=model -o wide; k logs -l app=model --tail=40 || true; return 1; }
    sleep 5
  done
  echo $((SECONDS - t0))
}

case "$phase" in
up)
  backend=${2:?backend: vllm | stub}
  HF_CACHE=${HF_CACHE:-$PWD/results/hf-cache}; mkdir -p "$HF_CACHE"
  # Static CPU manager: Guaranteed pods with an integer CPU get exclusive
  # cores, and the policy keeps one core as the shared pool (README "Set-up").
  # The policy needs a non-zero reservation; 10m keeps the allocatable CPU
  # at 3.99, enough for 3 exclusive cores plus the control plane's requests
  # (about 0.95) on a 4-CPU runner. Helper pods request no CPU.
  cat > results/kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $HF_CACHE
        containerPath: /hf-cache
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        cpuManagerPolicy: static
        systemReserved:
          cpu: 10m
EOF
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config results/kind.yaml --wait 120s | tee -a "$LOG"
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  say "kind $(kind version); kubernetes $(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
  say "cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1), $(nproc) cpus, $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  say "node allocatable: $(kubectl get node -o jsonpath='{.items[0].status.allocatable}')"
  # Images by tag pulled on the runner, digests printed, loaded into the node.
  # LOADGEN_IMAGE is pinned by digest and pulled by the node itself: a
  # digest-referenced image loaded with `kind load` fails to start
  # (CreateContainerError "failed to check if this is a checkpoint image",
  # smoke of 2026-11-27).
  for img in "$ROLLOUTS_IMAGE" "$PROMETHEUS_IMAGE"; do
    for i in 1 2 3; do docker pull -q "$img" >/dev/null && break; sleep $((20 * i)); done
    say "image $img = $(docker image inspect --format '{{index .RepoDigests 0}}' "$img")"
    kind load docker-image "$img" --name "$CLUSTER" >/dev/null
  done
  # Argo Rollouts: the release's install.yaml, pinned by SHA-256.
  f=results/argo-rollouts-install.yaml
  [ -s "$f" ] || curl -fsSL --retry 3 -o "$f" "https://github.com/argoproj/argo-rollouts/releases/download/$ROLLOUTS_VERSION/install.yaml"
  echo "$ROLLOUTS_INSTALL_SHA256  $f" | sha256sum -c - | tee -a "$LOG"
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n argo-rollouts --server-side -f "$f" >/dev/null
  kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s | tee -a "$LOG"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed "s|__PROMETHEUS_IMAGE__|$PROMETHEUS_IMAGE|" manifests/prometheus.yaml | k apply -f - >/dev/null
  k apply -f manifests/analysis.yaml -f ../prefix-routing/manifests/service.yaml >/dev/null
  k rollout status deploy/prometheus --timeout=300s | tee -a "$LOG"
  [ "$backend" = stub ] && k create configmap stub-vllm --from-file=stub_vllm.py --dry-run=client -o yaml | k apply -f - >/dev/null
  say "up: Argo Rollouts $ROLLOUTS_VERSION, Prometheus, AnalysisTemplate slo-ttft, Service model"
  ;;
backend)
  kind_=${2:?kind: rollout | deployment}; backend=${3:?backend: vllm | stub}
  k delete rollout model --ignore-not-found --wait >/dev/null 2>&1 || true
  k delete deployment model --ignore-not-found --wait >/dev/null
  k delete analysisrun --all --ignore-not-found >/dev/null 2>&1 || true
  k wait --for=delete pod -l app=model --timeout=180s >/dev/null 2>&1 || true
  python3 workload.py "$kind_" v1 "$backend" | k apply -f - >/dev/null
  s=$(wait_serving 2 v1 900)
  say "backend $kind_ $backend: 2 v1 pods serving after $s s"
  for p in $(k get pods -l app=model -o name); do k logs "$p" | grep -m1 'bound to cores' | tee -a "$LOG" || true; done
  ;;
calibrate)
  # T, P and C with the rules and code of step 7, on the v1 pods.
  bash "$TR/run.sh" trace
  bash "$TR/run.sh" calibrate "$TRACE"
  cp "$TR/results/calib-$TRACE.json" "$TR/results/schedule-$TRACE.json" results/
  cp "$TR"/results/calib-"$TRACE"-*.jsonl results/ 2>/dev/null || true
  bash run.sh tb
  ;;
tb)
  # T_b: smallest `le` of vLLM's TTFT histogram at or above T, as Prometheus stores it.
  T=$(python3 -c "import json; print(json.load(open('results/calib-$TRACE.json'))['T'])")
  # Waits (up to 3 min) for the first scrape of the model pods.
  k run promq --restart=Never --image="$LOADGEN_IMAGE" --command -- python3 -c '
import json, sys, time, urllib.parse as p, urllib.request as u
q = p.urlencode({"match[]": "vllm:time_to_first_token_seconds_bucket"})
for _ in range(36):
    d = json.load(u.urlopen(f"http://prometheus:9090/api/v1/label/le/values?{q}", timeout=30))["data"]
    if d:
        break
    time.sleep(5)
else:
    for t in json.load(u.urlopen("http://prometheus:9090/api/v1/targets", timeout=30))["data"]["activeTargets"]:
        print("target", t["scrapeUrl"], t["health"], t["lastError"], file=sys.stderr)
print(json.dumps(d))' >/dev/null
  k wait --for=jsonpath='{.status.phase}'=Succeeded pod/promq --timeout=300s >/dev/null
  k logs promq | grep '^target ' | tee -a "$LOG" || true
  les=$(k logs promq | grep -v '^target '); k delete pod promq --wait >/dev/null
  python3 - "$T" "$les" > results/tb.json <<'PY'
import json, sys
t, les = float(sys.argv[1]), json.loads(sys.argv[2])
cands = sorted((float(l), l) for l in les if l != "+Inf" and float(l) >= t)
if not cands:
    sys.exit(f"no TTFT bucket at or above T = {t} s in Prometheus: {les}")
print(json.dumps({"T": t, "T_b": cands[0][0], "le": cands[0][1], "buckets": les}))
PY
  say "calibrate: $(cat results/calib-$TRACE.json); T_b $(python3 -c "import json; d=json.load(open('results/tb.json')); print(d['T_b'], 'le=' + d['le'])")"
  ;;
rep)
  name=${2:?name}; kind_=${3:?kind}; version=${4:?version: none | v2-good | v2-bad}; backend=${5:?backend}
  export TB_LE; TB_LE=$(python3 -c "import json; print(json.load(open('results/tb.json'))['le'])")
  read -r T P < <(python3 -c "import json; c=json.load(open('results/calib-$TRACE.json')); print(c['T'], c['P'])")
  replay_s=$(python3 -c "import json; s=json.load(open('results/schedule-$TRACE.json')); print(int(s['meta'].get('replay_s', 1200)))")
  bash run.sh backend "$kind_" "$backend"
  rm -rf results/pod-input; mkdir -p results/pod-input
  cp "results/schedule-$TRACE.json" results/pod-input/schedule.json
  k create configmap replay-in --from-file=results/pod-input/ --from-file="$TR/replay.py" --dry-run=client -o yaml | k apply -f - >/dev/null
  k delete pod replay --ignore-not-found --wait >/dev/null
  rm -f "results/$name.watch.jsonl"
  python3 watch.py "$NS" "$kind_" $((replay_s + 180)) "results/$name.watch.jsonl" & wpid=$!
  args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /in/replay.py --arm "$name" --url http://model:8000 \
    --model "${MODEL_NAME:-$MODEL}" --schedule /in/schedule.json --ttft-slo "$T" --tpot-slo "$P")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: replay
spec:
  restartPolicy: Never
  containers:
    - name: replay
      image: $LOADGEN_IMAGE
      command: ["python3"]
      args: $args
      resources:
        requests: {memory: 128Mi}
      volumeMounts:
        - {name: in, mountPath: /in}
  volumes:
    - name: in
      configMap: {name: replay-in}
EOF
  k wait --for=jsonpath='{.status.phase}'=Running pod/replay --timeout=180s >/dev/null
  started=$(k get pod replay -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
  t_start=$(date -d "$started" +%s)
  say "rep $name: $kind_, version $version, replay started $started (T $T s, P $P s, le $TB_LE)"
  trigger=null
  if [ "$version" != none ]; then
    sleep $((t_start + TRIGGER_S - $(date +%s) > 0 ? t_start + TRIGGER_S - $(date +%s) : 0))
    python3 workload.py "$kind_" "$version" "$backend" | k apply -f - >/dev/null
    trigger=$(python3 -c 'import time; print(round(time.time(), 2))')
    say "rep $name: $version applied at +$(python3 -c "print(round($trigger - $t_start, 1))") s"
  fi
  t0=$SECONDS
  until [[ "$(k get pod replay -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt $((replay_s + 1800)) ] || { echo "replay timed out"; exit 1; }
    sleep 10
  done
  k logs replay > "results/$name.jsonl"
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  k get rollout model -o yaml > "results/$name.rollout.yaml" 2>/dev/null || true
  k get analysisrun -o yaml > "results/$name.analysisrun.yaml" 2>/dev/null || true
  k get events --sort-by=.lastTimestamp > "results/$name.events.txt" 2>/dev/null || true
  printf '{"name": "%s", "kind": "%s", "version": "%s", "replay_start": %s, "trigger": %s, "trigger_s": %s}\n' \
    "$name" "$kind_" "$version" "$t_start" "$trigger" "$TRIGGER_S" > "results/$name.meta.json"
  grep '"summary"' "results/$name.jsonl" | python3 -c 'import json,sys; s=json.loads(sys.stdin.read())["summary"]; s.pop("meta",None); print(json.dumps(s))' | tee -a "$LOG"
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
