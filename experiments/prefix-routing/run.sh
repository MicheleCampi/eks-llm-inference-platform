#!/usr/bin/env bash
# Prefix-aware routing (llm-d-router) against kube-proxy, on kind, CPU only,
# zero cloud cost. Protocol and hypotheses: README.md (written before any run).
# Phases, one per command:
#   bash run.sh up                     kind cluster (model cache mounted), namespace
#   bash run.sh backend sim|vllm       model servers: simulator (4) or vLLM CPU (2)
#   bash run.sh arm ARM REP            one measured run; ARM = service | random | prefix
#   bash run.sh report                 table of every summary in results/
#   bash run.sh down                   delete the kind cluster
# Every arm starts from empty prefix caches on every replica and, for the
# router arms, from a fresh EPP (empty prefix index).
# Needs: docker, kind, kubectl, helm 3, python3. The vllm backend also needs
# the image loaded as vllm-cpu-ci:pinned and the model in $HF_CACHE (CI does
# both, see .github/workflows/prefix-routing.yml).
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
mkdir -p results
phase=${1:?phase: up | backend | arm | report | down}
LOG="results/run.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
k() { kubectl -n "$NS" "$@"; }
# Public charts, pulled anonymously (a stale ghcr.io login in
# ~/.docker/config.json gets 403 on public charts: kind-serving, 2026-11-19).
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

backend_kind() { k get statefulset model >/dev/null 2>&1 && echo vllm || echo sim; }
# Ready pods only, never one that is terminating (a rollout restart leaves the
# old pods listed for a while; run 45284208834 scraped one and timed out).
pod_targets() {
  k get pods -l app=model -o json | python3 -c '
import json, sys
ps = json.load(sys.stdin)["items"]
ok = [p["status"]["podIP"] + ":8000" for p in ps
      if not p["metadata"].get("deletionTimestamp")
      and any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))]
print(",".join(sorted(ok)))'
}

# Empty prefix caches on every replica before each arm.
reset_backend() {
  if [ "$(backend_kind)" = vllm ]; then
    for p in $(k get pods -l app=model -o name); do
      k exec "$p" -- python3 -c 'import urllib.request as u; r=u.urlopen(u.Request("http://127.0.0.1:8000/reset_prefix_cache", method="POST"), timeout=30); print(r.status)' \
        | sed "s|^|reset_prefix_cache $p: HTTP |" | tee -a "$LOG"
    done
  else
    k rollout restart deploy/model >/dev/null
    k rollout status deploy/model --timeout=180s | tee -a "$LOG"
    want=$(k get deploy model -o jsonpath='{.spec.replicas}')
    for _ in $(seq 1 60); do
      [ "$(k get pods -l app=model --no-headers | wc -l)" = "$want" ] && break
      sleep 2
    done
  fi
}

case "$phase" in
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
  k create configmap loadgen --from-file=loadgen.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k apply -f manifests/service.yaml >/dev/null
  ;;
backend)
  b=${2:?backend: sim | vllm}
  if [ "$b" = sim ]; then
    sed "s|SIM_IMAGE|$SIM_IMAGE|" manifests/sim.yaml | k apply -f - >/dev/null
    k rollout status deploy/model --timeout=300s | tee -a "$LOG"
  else
    sed -e "s|__MODEL__|$MODEL|" -e "s|__MODEL_REVISION__|$MODEL_REVISION|" manifests/vllm.yaml | k apply -f - >/dev/null
    t0=$SECONDS
    until [ "$(k get statefulset model -o jsonpath='{.status.readyReplicas}')" = 2 ]; do
      [ $((SECONDS - t0)) -lt 900 ] || { k logs -l app=model --tail=50 || true; exit 1; }
      echo "$((SECONDS - t0)) s: $(k get pods -l app=model --no-headers | awk '{print $1" "$2" "$3}' | paste -sd' ')"
      sleep 15
    done
    say "vllm: 2 replicas Ready after $((SECONDS - t0)) s"
    k logs model-0 | grep -iE 'bound to cores|num_gpu_blocks|KV cache|prefix|block_size' | head -10 | tee -a "$LOG" || true
  fi
  say "backend $b: $(pod_targets)"
  ;;
arm)
  arm=${2:?arm: service | random | prefix}; rep=${3:-1}
  b=$(backend_kind)
  out="results/$b-$arm-$rep.jsonl"
  reset_backend
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  case "$arm" in
    service) url="http://model:8000" ;;
    random|prefix)
      helm upgrade -i router "$ROUTER_CHART" --version "$ROUTER_VERSION" -n "$NS" --wait --timeout 300s \
        -f values/router.yaml -f "values/$arm.yaml" \
        --set router.epp.image.tag="$EPP_IMAGE_TAG" --set router.proxy.image="$ENVOY_IMAGE" >/dev/null
      k rollout status deploy/router-epp --timeout=300s | tee -a "$LOG"
      sleep 15  # EPP discovers the pods and scrapes their metrics at least once
      url="http://router-epp:8081" ;;
    *) echo "unknown arm $arm"; exit 1 ;;
  esac
  if [ "$b" = vllm ]; then
    model=$MODEL; extra=(--requests "${REQUESTS:-160}" --concurrency "${CONCURRENCY:-4}")
  else
    model=sim-qwen2.5-0.5b; extra=(--requests "${REQUESTS:-800}" --concurrency "${CONCURRENCY:-16}")
  fi
  say "arm $arm rep $rep on $b via $url"
  k delete pod loadgen --ignore-not-found --wait >/dev/null
  args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' /app/loadgen.py \
    --arm "$arm" --url "$url" --model "$model" --pods "$(pod_targets)" "${extra[@]}")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
spec:
  restartPolicy: Never
  containers:
    - name: loadgen
      image: $LOADGEN_IMAGE
      command: ["python3"]
      args: $args
      resources:
        requests: {cpu: 100m, memory: 64Mi}
      volumeMounts:
        - {name: app, mountPath: /app}
  volumes:
    - name: app
      configMap: {name: loadgen}
EOF
  t0=$SECONDS
  until [[ "$(k get pod loadgen -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do
    [ $((SECONDS - t0)) -lt 3600 ] || { echo "loadgen timed out"; exit 1; }
    sleep 10
  done
  k logs loadgen > "$out"
  [ "$(k get pod loadgen -o jsonpath='{.status.phase}')" = Succeeded ] || { tail -20 "$out"; exit 1; }
  grep '"summary"' "$out" | tee -a "$LOG"
  if [ "$arm" != service ]; then k logs deploy/router-epp -c epp --tail=2000 > "results/$b-$arm-$rep.epp.log" 2>&1 || true; fi
  helm uninstall router -n "$NS" --wait >/dev/null 2>&1 || true
  ;;
report)
  ls results/*.jsonl >/dev/null 2>&1 || { echo "no results yet"; exit 0; }
  python3 - results/*.jsonl <<'PY' | tee results/report.md
import json, sys, statistics as st
rows = {}
for f in sys.argv[1:]:
    b = f.split("/")[-1].split("-")[0]
    for line in open(f):
        if '"summary"' in line:
            s = json.loads(line)["summary"]
            rows.setdefault((b, s["arm"]), []).append(s)
med = lambda xs: st.median(xs) if xs else float("nan")
print("| backend | arm | runs | requests ok/total | prefix hit rate | TTFT p50 s | TTFT p90 s | TTFT mean s | wall s | requests per replica |")
print("|---|---|---|---|---|---|---|---|---|---|")
for (b, arm), ss in sorted(rows.items(), key=lambda kv: (kv[0][0], ["service", "random", "prefix"].index(kv[0][1]) if kv[0][1] in ("service", "random", "prefix") else 9)):
    ok = sum(s["ok"] for s in ss); tot = sum(s["requests"] for s in ss)
    hr = ", ".join(f'{s["hit_rate"]:.3f}' for s in ss)
    spread = " / ".join(",".join(str(int(p["success"])) for p in s["per_pod"].values()) for s in ss)
    print(f'| {b} | {arm} | {len(ss)} | {ok}/{tot} | {hr} | {med([s["ttft_p50"] for s in ss]):.3f} | {med([s["ttft_p90"] for s in ss]):.3f} | {med([s["ttft_mean"] for s in ss]):.3f} | {med([s["wall_s"] for s in ss]):.1f} | {spread} |')
for b in sorted({b for b, _ in rows}):
    s0 = next(ss[0] for (bb, _), ss in rows.items() if bb == b)
    print(f'\n{b}: {s0["replicas"]} replicas, {s0["requests"]} requests per arm at concurrency {s0["concurrency"]}; {s0["groups"]} groups (shared prefixes) of {s0["prefix_words"]} words, {s0["question_words"]}-word unique question, {s0["max_tokens"]} output tokens, seed {s0["seed"]}; capacity {s0["capacity_tokens_per_replica"]} tokens per replica.')
PY
  ;;
down)
  kind delete cluster --name "$CLUSTER"
  ;;
*) echo "unknown phase $phase"; exit 1 ;;
esac
