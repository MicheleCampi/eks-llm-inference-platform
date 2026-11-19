#!/usr/bin/env bash
# Serving control planes compared on kind, CPU only, zero cloud cost.
# Phases, one per command (project rule: one command at a time):
#   bash experiments/kind-serving/run.sh up        kind cluster, cert-manager, KServe, operator, Kueue
#   bash experiments/kind-serving/run.sh operator  path A: VllmService, timed, 20 requests, removed
#   bash experiments/kind-serving/run.sh kserve    path B: InferenceService, same measures, removed
#   bash experiments/kind-serving/run.sh kueue     path C: 6 jobs from 2 teams against a 2 CPU quota
#   bash experiments/kind-serving/run.sh report    footprint of each control plane
#   bash experiments/kind-serving/run.sh down      delete the kind cluster
# Every phase appends to experiments/kind-serving/results/<phase>.log.
# Needs: docker, kind >= v0.30.0, kubectl, helm 3, git, curl, python3;
# at least 6.5 GiB of available RAM: the model peaked at 5.0 GiB in the Docker
# pre-check of live #4 (6 GiB limit, VLLM_CPU_KVCACHE_SPACE=1), plus about
# 1.5 GiB for kind, cert-manager, KServe, the operator and Kueue. One model at
# a time; the node's memory is logged in each serving phase, so the margin is
# measured, not assumed.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
mkdir -p results
phase=${1:?phase: up | operator | kserve | kueue | report | down}
LOG="results/$phase.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
# Every chart here is public: helm pulls them anonymously. Without this, helm
# falls back to ~/.docker/config.json and sends whatever ghcr.io login is
# there; a stale one gets 403 on public KServe charts (optim-dev, 2026-11-19).
# Scoped to helm, so docker and kind keep the user's own configuration.
HELM_ANON=$(mktemp -d); trap 'rm -rf "${HELM_ANON:?}"' EXIT
echo '{}' > "$HELM_ANON/config.json"
helm() { DOCKER_CONFIG="$HELM_ANON" HELM_REGISTRY_CONFIG="$HELM_ANON/config.json" command helm "$@"; }

# 20 completions through a port-forward; prints p50 and max like the live runbook.
probe() { # namespace service
  local pf
  kubectl -n "$1" port-forward "svc/$2" 18000:"${3:-8000}" >/dev/null 2>&1 & pf=$!
  sleep 3
  for _ in $(seq 1 20); do
    curl -s -o /dev/null -m 60 -w '%{http_code} %{time_total}\n' localhost:18000/v1/completions \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"prompt\":\"Kubernetes is\",\"max_tokens\":32}"
  done | tee -a "$LOG" | python3 -c '
import sys
rows = [l.split() for l in sys.stdin if l.strip()]
ok = [float(t) for c, t in rows if c == "200"]
ok.sort()
print(f"answers 200: {len(ok)}/{len(rows)}; p50 {ok[len(ok)//2]:.2f} s; max {ok[-1]:.2f} s" if ok else "no answer 200")' | tee -a "$LOG"
  kill "$pf" 2>/dev/null || true
}

# Memory of the kind node (the whole cluster) as Docker sees it.
mem() { say "node memory ($1): $(docker stats --no-stream --format '{{.MemUsage}}' "$CLUSTER-control-plane")"; }

# Seconds from a start epoch to now.
since() { echo $(( $(date +%s) - $1 )); }

case "$phase" in
up)
  for t in docker kind kubectl helm git curl python3; do need "$t"; done
  avail_mib=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
  [ "$avail_mib" -ge 6656 ] || { echo "only ${avail_mib} MiB of RAM available, need 6656 (6.5 GiB)"; exit 1; }
  say "RAM available before kind: ${avail_mib} MiB"
  say "kind $(kind version)"
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s | tee -a "$LOG"
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  say "kubernetes $(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
  say "cert-manager $CERT_MANAGER_VERSION"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >> "$LOG"
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s | tee -a "$LOG"
  say "KServe $KSERVE_VERSION, Standard mode, no Knative, no Istio, no ingress"
  helm upgrade -i kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version "$KSERVE_VERSION" -n kserve --create-namespace --wait | tee -a "$LOG"
  helm upgrade -i kserve-resources oci://ghcr.io/kserve/charts/kserve-resources --version "$KSERVE_VERSION" -n kserve --wait \
    --set kserve.controller.deploymentMode=Standard \
    --set kserve.controller.gateway.disableIngressCreation=true | tee -a "$LOG"
  say "operator $OPERATOR_VERSION from its chart at that tag"
  rm -rf .operator-src
  git clone -q --depth 1 --branch "$OPERATOR_VERSION" https://github.com/MicheleCampi/vllm-coldstart-operator.git .operator-src
  helm upgrade -i vcso .operator-src/chart -n vllm-operator-system --create-namespace --set example.enabled=false --wait | tee -a "$LOG"
  say "Kueue $KUEUE_VERSION"
  helm upgrade -i kueue oci://registry.k8s.io/kueue/charts/kueue --version "$KUEUE_VERSION" -n kueue-system --create-namespace --wait | tee -a "$LOG"
  say "pre-pulling the vLLM CPU image into the node once (1.12 GB), so neither path pays the pull"
  docker pull -q "$VLLM_CPU_IMAGE" | tee -a "$LOG"
  kind load docker-image "$VLLM_CPU_IMAGE" --name "$CLUSTER" | tee -a "$LOG"
  mem "control planes up, no model"
  say "UP DONE"
  ;;
operator)
  kubectl create namespace cmp-operator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  t0=$(date +%s); say "apply VllmService"
  kubectl apply -f manifests/vllmservice.yaml | tee -a "$LOG"
  kubectl -n cmp-operator wait vllmservice/qwen --for=jsonpath='{.status.phase}'=Ready --timeout=600s | tee -a "$LOG"
  say "READY after $(since "$t0") s (apply -> VllmService Ready)"
  mem "model ready"
  say "objects created: $(kubectl -n cmp-operator get all,networkpolicy -o name | tr '\n' ' ')"
  probe cmp-operator qwen 8000
  mem "after 20 requests"
  kubectl delete -f manifests/vllmservice.yaml --wait | tee -a "$LOG"
  kubectl delete namespace cmp-operator --wait | tee -a "$LOG"
  ;;
kserve)
  kubectl create namespace cmp-kserve --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  t0=$(date +%s); say "apply InferenceService"
  kubectl apply -f manifests/inferenceservice.yaml | tee -a "$LOG"
  kubectl -n cmp-kserve wait inferenceservice/qwen --for=condition=Ready --timeout=600s | tee -a "$LOG"
  say "READY after $(since "$t0") s (apply -> InferenceService Ready)"
  mem "model ready"
  say "objects created: $(kubectl -n cmp-kserve get all,hpa -o name | tr '\n' ' ')"
  svc=$(kubectl -n cmp-kserve get svc -o name | grep predictor | head -1 | cut -d/ -f2)
  port=$(kubectl -n cmp-kserve get svc "$svc" -o jsonpath='{.spec.ports[0].port}')
  say "predictor service $svc port $port"
  probe cmp-kserve "$svc" "$port"
  mem "after 20 requests"
  kubectl delete -f manifests/inferenceservice.yaml --wait | tee -a "$LOG"
  kubectl delete namespace cmp-kserve --wait | tee -a "$LOG"
  ;;
kueue)
  kubectl apply -f manifests/kueue.yaml | tee -a "$LOG"
  t0=$(date +%s)
  for team in team-a team-b team-a team-b team-a team-b; do
    kubectl -n "$team" create -f manifests/kueue-job.yaml -o name | tee -a "$LOG"
  done
  say "6 jobs x 1 CPU submitted against a 2 CPU quota; sampling every 15 s"
  while :; do
    adm=$(kubectl get workloads -A -o jsonpath='{range .items[?(@.status.admission)]}{.metadata.namespace}{"\n"}{end}' | wc -l)
    done_n=$(kubectl get jobs -A -l kueue.x-k8s.io/queue-name=batch -o jsonpath='{range .items[?(@.status.succeeded==1)]}x{"\n"}{end}' | wc -l)
    pend=$(kubectl get pods -A --field-selector=status.phase=Pending -o name | wc -l)
    say "t=$(since "$t0")s admitted=$adm succeeded=$done_n pending_pods=$pend"
    [ "$done_n" -ge 6 ] && break
    [ "$(since "$t0")" -gt 600 ] && { say "TIMEOUT"; break; }
    sleep 15
  done
  kubectl get workloads -A -o wide | tee -a "$LOG"
  kubectl get clusterqueue shared -o jsonpath='{.status}' | tee -a "$LOG"; echo | tee -a "$LOG"
  ;;
report)
  say "control-plane footprint (resource requests as installed)"
  for ns in kserve vllm-operator-system kueue-system cert-manager; do
    kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: requests {.spec.template.spec.containers[*].resources.requests}{"\n"}{end}' | tee -a "$LOG"
  done
  say "CRDs installed: kserve $(kubectl get crd -o name | grep -c serving.kserve.io), operator $(kubectl get crd -o name | grep -c inference.michelecampi.dev), kueue $(kubectl get crd -o name | grep -c kueue.x-k8s.io)"
  say "lines a team writes: operator $(grep -cv '^\s*#' manifests/vllmservice.yaml), kserve $(grep -cv '^\s*#' manifests/inferenceservice.yaml)"
  say "copy results/*.log into the thread; the ADR is written from them"
  ;;
down)
  kind delete cluster --name "$CLUSTER" | tee -a "$LOG"
  rm -rf .operator-src
  ;;
*) echo "unknown phase: $phase"; exit 1 ;;
esac
