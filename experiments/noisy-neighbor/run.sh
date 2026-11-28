#!/usr/bin/env bash
# Noisy neighbor: a separate premium pool against a shared pool, with the
# tenancy guardrails checked by requests that must be refused, on kind.
# Protocol and hypotheses: README.md (written before any run).
# Reuses ../trace-replay (trace, calibration, replayer) and ../prefix-routing
# (pins, Service model), and ../finops-guardrail/report.py (SLOs per tenant,
# EUR per million good tokens).
# Phases, one per command:
#   bash run.sh up                trace pinned, kind with 3 pools, tenants, admission policy, Kueue
#   bash run.sh load              load the vLLM image into the two model nodes
#   bash run.sh backend BACKEND   BACKEND = vllm | sim: model-premium and model-batch
#   bash run.sh calibrate         T, P and C with the step 7 code (vllm), replay at 1.5 x C
#   bash run.sh checks            H3 (NetworkPolicy, quota, taint, admission) and H4 (Kueue)
#   bash run.sh arm ARM NAME      ARM = shared | isolated; both tenants' clients together
#   bash run.sh report            tables and H1-H4 of every result in results/
#   bash run.sh down              delete the kind cluster
set -euo pipefail
cd "$(dirname "$0")"
TR=../trace-replay
PR=../prefix-routing
. "$PR/versions.env"
CLUSTER=trace-replay   # the name ../trace-replay/run.sh works on
TRACE=conv
mkdir -p results
phase=${1:?phase: up | load | backend | calibrate | checks | arm | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }

# Fixed in README.md; changing one is an amendment.
TENANTS="premium=0.2,batch"
BATCH_TTFT_X=10
LOAD_X=1.5               # mean offered rate = 1.5 x C, as finops-guardrail amendment 2
SEED=20261126            # the step 7 thinning seed
LADDER=${LADDER:-"0.0625 0.125 0.25 0.5 1 2 4 8"}  # amendment 1: two rungs below the step 7 ladder
KUEUE_VERSION=v0.20.8    # latest release, read 2026-11-28 (tag commit 31ed51aa)
KUEUE_URL=https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml
KUEUE_SHA256=ecbc26a9ba2674e1829ed44efb1312c6f8dfa08de96dbbdeb91385535319290a

calib() { python3 -c "import json; c=json.load(open('$TR/results/calib-$TRACE.json')); print(c['$1'])"; }

# Empty both replicas' prefix caches over HTTP from a pod in bench, as
# ../trace-replay does before each arm (no exec into the vLLM container).
reset_backend() {
  local ips
  ips=$(k get pods -l app=model -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')
  k delete pod reset --ignore-not-found --wait >/dev/null
  k run reset --restart=Never --image="$LOADGEN_IMAGE" --command -- python3 -c '
import sys, urllib.request as u
for ip in sys.argv[1:]:
    try:
        r = u.urlopen(u.Request(f"http://{ip}:8000/reset_prefix_cache", method="POST"), timeout=30)
        print(f"reset_prefix_cache {ip}: HTTP {r.status}")
    except Exception as e:
        print(f"reset_prefix_cache {ip}: {e}")' $ips >/dev/null
  k wait --for=jsonpath='{.status.phase}'=Succeeded pod/reset --timeout=120s >/dev/null
  k logs reset | tee -a "$LOG"
  k delete pod reset --wait >/dev/null
}

# probe NS URL: "open" if a TCP connection to URL's host:port succeeds within 5 s.
probe() {
  local ns=$1 host=$2 out
  kubectl -n "$ns" delete pod probe --ignore-not-found --wait >/dev/null
  kubectl -n "$ns" run probe --restart=Never --image="$LOADGEN_IMAGE" --command -- python3 -c '
import socket, sys
try:
    socket.create_connection((sys.argv[1], 8000), timeout=5).close(); print("open")
except Exception as e:
    print("closed", type(e).__name__)' "$host" >/dev/null
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=120s >/dev/null
  out=$(kubectl -n "$ns" logs probe)
  kubectl -n "$ns" delete pod probe --wait >/dev/null
  echo "$out"
}

# check NAME OK DETAIL: one line of results/checks.json.
check() {
  python3 -c 'import json,sys; print(json.dumps({"check": sys.argv[1], "ok": sys.argv[2] == "1", "detail": sys.argv[3]}))' "$1" "$2" "$3" \
    | tee -a results/checks.jsonl | tee -a "$LOG"
}

# client NS NAME KIND ARGS...: the replayer as a Pod (premium) or a Kueue Job (batch).
client() {
  local ns=$1 name=$2 kind=$3; shift 3
  kubectl -n "$ns" create configmap "$name-in" --from-file="$TR/results/schedule-$TRACE.json" --from-file="$TR/replay.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local args; args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /in/replay.py "$@")
  local spec="restartPolicy: Never
      nodeSelector: {pool: system}
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: replay
          image: $LOADGEN_IMAGE
          command: [python3]
          args: $args
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          resources:
            requests: {cpu: 200m, memory: 128Mi}
            limits: {cpu: '1', memory: 1Gi}
          volumeMounts:
            - {name: in, mountPath: /in}
      volumes:
        - name: in
          configMap: {name: $name-in}"
  if [ "$kind" = job ]; then
    kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  labels: {kueue.x-k8s.io/queue-name: batch}
spec:
  suspend: true
  backoffLimit: 0
  template:
    spec:
      $spec
EOF
  else
    kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
      $spec
EOF
  fi
}

# client_phase NS NAME: Succeeded | Failed | Running | Pending (pod, or the Job's pod).
client_phase() {
  kubectl -n "$1" get pods -l "batch.kubernetes.io/job-name=$2" -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
    || kubectl -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending
}

case "$phase" in
up)
  bash "$TR/run.sh" trace
  HF_CACHE=${HF_CACHE:-$PWD/$TR/results/hf-cache}; mkdir -p "$HF_CACHE"
  # Four nodes: control plane, pool=system (clients, Kueue, calibration),
  # pool=premium and pool=batch (one model replica each, both tainted).
  cat > results/kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    labels: {pool: system}
  - role: worker
    labels: {pool: premium}
    extraMounts:
      - {hostPath: $HF_CACHE, containerPath: /hf-cache}
  - role: worker
    labels: {pool: batch}
    extraMounts:
      - {hostPath: $HF_CACHE, containerPath: /hf-cache}
EOF
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config results/kind.yaml --wait 180s | tee -a "$LOG"
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  for p in premium batch; do kubectl taint nodes -l "pool=$p" "pool=$p:NoSchedule" --overwrite >/dev/null; done
  bash "$TR/run.sh" up   # cluster exists: namespace bench and Service model only
  kubectl label namespace "$NS" platform.michelecampi.dev/premium-pool=allowed --overwrite >/dev/null
  for t in premium batch; do
    pp=$([ "$t" = premium ] && echo allowed || echo denied)
    sed -e "s|__TENANT__|$t|g" -e "s|__PREMIUM_POOL__|$pp|" manifests/tenant.yaml | kubectl apply -f - >/dev/null
  done
  kubectl apply -f manifests/premium-pool-policy.yaml >/dev/null
  [ -s results/kueue.yaml ] || curl -fsSL --retry 3 -o results/kueue.yaml "$KUEUE_URL"
  echo "$KUEUE_SHA256  results/kueue.yaml" | sha256sum -c - | tee -a "$LOG"
  kubectl apply --server-side -f results/kueue.yaml >/dev/null
  kubectl -n kueue-system wait deploy/kueue-controller-manager --for=condition=Available --timeout=300s >/dev/null
  # The webhook answers a little after the Deployment is Available.
  for i in $(seq 1 30); do kubectl apply -f manifests/kueue-queues.yaml >/dev/null 2>&1 && break; sleep 5; done
  kubectl apply -f manifests/kueue-queues.yaml >/dev/null
  say "up: nodes $(kubectl get nodes -L pool --no-headers | awk '{print $1"="$NF}' | paste -sd' ')"
  say "up: kueue $KUEUE_VERSION image $(kubectl -n kueue-system get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  ;;
load)
  nodes=$(kubectl get nodes -l 'pool in (premium,batch)' -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}')
  kind load docker-image vllm-cpu-ci:pinned --name "$CLUSTER" --nodes "${nodes%,}"
  ;;
backend)
  backend=${2:?backend: vllm | sim}
  for p in premium batch; do
    cores=$([ "$p" = premium ] && echo 0-1 || echo 2-3)
    if [ "$backend" = sim ]; then
      sed -e "s|__POOL__|$p|g" -e "s|SIM_IMAGE|$SIM_IMAGE|" manifests/model-sim.yaml
    else
      sed -e "s|__POOL__|$p|g" -e "s|__CORES__|$cores|" -e "s|__MODEL__|$MODEL|" -e "s|__MODEL_REVISION__|$MODEL_REVISION|" manifests/model.yaml
    fi | k apply -f - >/dev/null
  done
  kubectl apply -f arms/shared.yaml >/dev/null
  for p in premium batch; do k rollout status "deploy/model-$p" --timeout=900s | tee -a "$LOG"; done
  k get pods -l app=model -o wide | tee -a "$LOG"
  [ "$backend" = sim ] || for p in premium batch; do k logs "deploy/model-$p" | grep -iE 'bound to cores|KV cache' | head -3 | tee -a "$LOG" || true; done
  say "backend $backend ready"
  ;;
calibrate)
  kubectl apply -f arms/shared.yaml >/dev/null
  LADDER="$LADDER" bash "$TR/run.sh" calibrate "$TRACE"
  C=$(calib C)
  rate=$(python3 -c "print(round($LOAD_X * $C, 4))")
  python3 "$TR/trace.py" thin "$TR/results/window-$TRACE.json" "$rate" "$SEED" "$TR/results/schedule-$TRACE.json" | tee -a "$LOG"
  python3 - "$TR/results/calib-$TRACE.json" "$rate" "$LOAD_X" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.update(rate=float(sys.argv[2]), load_x=float(sys.argv[3]))
json.dump(c, open(sys.argv[1], "w"))
PY
  say "calibrate: replay at $LOAD_X x C = $rate req/s mean"
  ;;
checks)
  rm -f results/checks.jsonl
  # H3 (a): NetworkPolicy in the isolated configuration.
  kubectl apply -f arms/isolated.yaml >/dev/null; sleep 10
  a1=$(probe tenant-batch "model-premium.$NS"); a2=$(probe tenant-batch "model-batch.$NS"); a3=$(probe tenant-premium "model-premium.$NS")
  check H3a-netpol "$([[ $a1 == closed* && $a2 == open && $a3 == open ]] && echo 1 || echo 0)" \
    "batch->premium: $a1; batch->batch: $a2; premium->premium: $a3"
  kubectl apply -f arms/shared.yaml >/dev/null
  pod() {  # pod NAME CPU EXTRA_SPEC: a pause-like pod manifest
    cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $LOADGEN_IMAGE
      command: [sleep, "30"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: "$2", memory: 64Mi}, limits: {cpu: "$2", memory: 64Mi}}
$3
EOF
  }
  # H3 (b): ResourceQuota (requests.cpu 1) refuses a 2-CPU pod at admission.
  out=$(pod over-quota 2 "" | kubectl -n tenant-batch apply --dry-run=server -f - 2>&1 || true)
  check H3b-quota "$([[ $out == *"exceeded quota"* ]] && echo 1 || echo 0)" "$out"
  # H3 (c): the premium node's taint keeps a pod without the toleration off it.
  pod on-premium 100m "  nodeSelector: {pool: premium}" | kubectl -n tenant-batch apply -f - >/dev/null
  sleep 20
  ph=$(kubectl -n tenant-batch get pod on-premium -o jsonpath='{.status.phase}/{.spec.nodeName}')
  ev=$(kubectl -n tenant-batch get events --field-selector involvedObject.name=on-premium,reason=FailedScheduling -o jsonpath='{.items[0].message}' 2>/dev/null || true)
  kubectl -n tenant-batch delete pod on-premium --wait >/dev/null
  check H3c-taint "$([[ $ph == "Pending/" && $ev == *"untolerated taint"* ]] && echo 1 || echo 0)" "phase/node $ph; event: $ev"
  # H3 (d): the admission policy refuses the toleration outside premium namespaces.
  tol_key="  tolerations: [{key: pool, operator: Equal, value: premium, effect: NoSchedule}]"
  tol_all="  tolerations: [{operator: Exists}]"
  d1=$(pod tol-key 100m "$tol_key" | kubectl -n tenant-batch apply --dry-run=server -f - 2>&1 || true)
  d2=$(pod tol-all 100m "$tol_all" | kubectl -n tenant-batch apply --dry-run=server -f - 2>&1 || true)
  d3=$(pod tol-key 100m "$tol_key" | kubectl -n tenant-premium apply --dry-run=server -f - 2>&1 || true)
  check H3d-admission "$([[ $d1 == *premium-pool-tenants-only* && $d2 == *premium-pool-tenants-only* && $d3 == *created* ]] && echo 1 || echo 0)" \
    "batch key: $d1 | batch Exists: $d2 | premium key: $d3"
  # H4: two batch Jobs that fit the ClusterQueue one at a time.
  for j in kueue-a kueue-b; do
    kubectl -n tenant-batch apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $j
  labels: {kueue.x-k8s.io/queue-name: batch}
spec:
  suspend: true
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: {pool: system}
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: c
          image: $LOADGEN_IMAGE
          command: [sleep, "40"]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          resources: {requests: {cpu: 200m, memory: 128Mi}, limits: {cpu: 200m, memory: 128Mi}}
EOF
  done
  kubectl -n tenant-batch wait job/kueue-a job/kueue-b --for=condition=Complete --timeout=300s >/dev/null || true
  times=$(kubectl -n tenant-batch get job kueue-a kueue-b -o jsonpath='{range .items[*]}{.metadata.name} {.status.startTime} {.status.completionTime}{"\n"}{end}')
  wl=$(kubectl -n tenant-batch get workloads -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Admitted")].status} {end}')
  h4=$(python3 - "$times" <<'PY'
import datetime as dt, sys
rows = [l.split() for l in sys.argv[1].splitlines() if l.strip()]
p = lambda s: dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
ok = len(rows) == 2 and all(len(r) == 3 for r in rows)
if ok:
    (a, sa, ca), (b, sb, cb) = sorted(rows, key=lambda r: r[1])
    ok = p(sb) >= p(ca)   # the second starts only when the first has finished
print(1 if ok else 0)
PY
)
  check H4-kueue "$h4" "jobs (name start completion): $(echo "$times" | paste -sd';'); workloads: $wl"
  kubectl -n tenant-batch delete job kueue-a kueue-b --wait >/dev/null
  ;;
arm)
  arm=${2:?arm: shared | isolated}; name=${3:?name}
  T=$(calib T); P=$(calib P)
  model=${MODEL_NAME:-$MODEL}
  case "$arm" in
    shared) up_p="http://model.$NS:8000"; up_b="http://model.$NS:8000" ;;
    isolated) up_p="http://model-premium.$NS:8000"; up_b="http://model-batch.$NS:8000" ;;
    *) echo "unknown arm $arm"; exit 1 ;;
  esac
  kubectl apply -f "arms/$arm.yaml" >/dev/null; sleep 10
  [ -n "${MODEL_NAME:-}" ] || reset_backend
  bt=$(python3 -c "print(round($BATCH_TTFT_X * $T, 3))"); bp=$(python3 -c "print(round(2 * $P, 4))")
  start=$(( $(date +%s) + 45 ))
  say "arm $arm ($name): premium -> $up_p, batch -> $up_b; T $T s, P $P s, tenants $TENANTS, start $(date -u -d "@$start" +%H:%M:%SZ)"
  common=(--model "$model" --schedule "/in/schedule-$TRACE.json" --tenants "$TENANTS" --start-at "$start")
  client tenant-premium replay-premium pod --arm "$arm" --url "$up_p" --only-tenant premium --ttft-slo "$T" --tpot-slo "$P" "${common[@]}"
  client tenant-batch replay-batch job --arm "$arm" --url "$up_b" --only-tenant batch --ttft-slo "$bt" --tpot-slo "$bp" "${common[@]}"
  t0=$SECONDS
  until [[ "$(client_phase tenant-premium replay-premium)" =~ ^(Succeeded|Failed)$ && "$(client_phase tenant-batch replay-batch)" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt 4200 ] || { echo "$name timed out"; exit 1; }
    sleep 15
  done
  kubectl -n tenant-premium logs replay-premium > "results/$name.premium.jsonl"
  kubectl -n tenant-batch logs job/replay-batch > "results/$name.batch.jsonl"
  starts="premium pod $(kubectl -n tenant-premium get pod replay-premium -o jsonpath='{.status.startTime}'), batch job $(kubectl -n tenant-batch get job replay-batch -o jsonpath='{.status.startTime}')"
  say "arm $arm ($name): clients started: $starts (replay clock at $(date -u -d "@$start" +%H:%M:%SZ))"
  for t in premium batch; do [ "$(client_phase "tenant-$t" "replay-$t")" = Succeeded ] || { tail -20 "results/$name.$t.jsonl"; exit 1; }; done
  # One file per rep, as ../finops-guardrail/report.py reads it: both
  # tenants' requests and one summary whose window is the longer client.
  python3 - "results/$name.premium.jsonl" "results/$name.batch.jsonl" > "results/$name.jsonl" <<'PY'
import json, sys
walls = []
for f in sys.argv[1:]:
    for l in open(f):
        if l.startswith('{"req"'):
            print(l, end="")
        elif l.startswith('{"summary"'):
            walls.append(json.loads(l)["summary"]["wall_s"])
print(json.dumps({"summary": {"wall_s": max(walls)}}))
PY
  printf '{"name": "%s", "arm": "%s", "T": %s, "P": %s, "batch_ttft_x": %s, "tenants": "%s"}\n' \
    "$name" "$arm" "$T" "$P" "$BATCH_TTFT_X" "$TENANTS" > "results/$name.meta.json"
  python3 report.py --one "results/$name.jsonl" "results/$name.meta.json" | tee -a "$LOG"
  kubectl -n tenant-premium delete pod replay-premium --wait >/dev/null
  kubectl -n tenant-batch delete job replay-batch --wait >/dev/null
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
