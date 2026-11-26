#!/usr/bin/env bash
# Envoy-to-uvicorn keep-alive race, reproduced without a cluster or a model.
# Protocol and hypotheses: README.md (written before the measured runs).
#   bash run.sh ARM NAME KEEPALIVE_S GAP_MIN GAP_MAX N [ENVOY_IMAGE]
# ARM = chart | idle | retry (envoy.py); IDLE_S and RETRY_ON from the
# environment. Each call runs its own server, Envoy and client on free
# ports, so calls can run side by side. Output: results/NAME.jsonl (client),
# results/NAME.envoy.log (Envoy access log), results/NAME.versions.
# --disable-hot-restart lets several Envoys run on one host (no shared
# memory segment); it does not change request handling.
# Needs: docker, python3 with requirements.txt installed (PY, default python3).
set -euo pipefail
cd "$(dirname "$0")"
arm=$1 name=$2 ka=$3 gmin=$4 gmax=$5 n=$6
ENVOY_IMAGE=${7:-mirror.gcr.io/envoyproxy/envoy:distroless-v1.40.2@sha256:09ca6f2140a61ad8df11779a4a30d52b48433d444466328494f9188c9c35eded}
PY=${PY:-python3}
mkdir -p results
free_port() { "$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
sp=$(free_port); lp=$(free_port); ap=$(free_port)
cfg=$(mktemp --suffix=.json); chmod 644 "$cfg"
cleanup() { docker rm -f "ka-$name" >/dev/null 2>&1 || true; kill "${spid:-0}" 2>/dev/null || true; rm -f "$cfg"; }
trap cleanup EXIT
LISTEN_PORT=$lp ADMIN_PORT=$ap "$PY" envoy.py "$arm" > "$cfg"
VLLM_HTTP_TIMEOUT_KEEP_ALIVE=$ka PORT=$sp "$PY" server.py & spid=$!
docker rm -f "ka-$name" >/dev/null 2>&1 || true
docker run -d --name "ka-$name" --network host -v "$cfg:/etc/envoy/envoy.json:ro" "$ENVOY_IMAGE" \
  --concurrency 8 --disable-hot-restart --log-level warn -c /etc/envoy/envoy.json >/dev/null
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "127.0.0.1:$ap/ready" && curl -sf -o /dev/null -XPOST "127.0.0.1:$sp/v1/completions" && break
  sleep 0.5
done
curl -sf -o /dev/null "127.0.0.1:$ap/ready" || { docker logs "ka-$name" 2>&1 | tail -5; exit 1; }
{ echo "arm=$arm keepalive_s=$ka gap=[$gmin,$gmax] n=$n idle_s=${IDLE_S:-} retry_on=${RETRY_ON:-}"
  echo "envoy=$ENVOY_IMAGE"; docker exec "ka-$name" envoy --version 2>/dev/null | tail -1 || true
  "$PY" -c 'import importlib.metadata as m; print(" ".join(f"{p}=={m.version(p)}" for p in ("uvicorn","fastapi","httptools","uvloop","h11","aiohttp")))'
  echo "cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1), $(nproc) cpus"
} > "results/$name.versions"
# Warm-up request (index 0, gap 0) opens the pooled connection; it is counted
# but its gap is 0, so it is outside every gap window.
DEST=127.0.0.1:$sp URL=http://127.0.0.1:$lp/v1/completions N=$n GAP_MIN=$gmin GAP_MAX=$gmax \
  "$PY" client.py > "results/$name.jsonl"
docker logs "ka-$name" 2>/dev/null | grep '^{' > "results/$name.envoy.log" || true
"$PY" report.py "results/$name.jsonl"
