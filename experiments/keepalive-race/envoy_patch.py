"""Applies one arm to the Envoy config rendered by the llm-d-router-standalone
chart: reads `kubectl get configmap -o json` on stdin, writes the patched
ConfigMap as JSON on stdout. Same arms as envoy.py:
  chart   unchanged
  idle    upstream idle_timeout IDLE_S on original_destination_cluster (and
          on inference_pool_fallback when the chart renders it)
  retry   retry_policy retry_on RETRY_ON, 1 retry, on every route to it
Fails if the cluster or a route to it is not found, so a chart change
cannot turn an arm into a silent no-op. Also used, arm idle, by the router
installs of ../prefix-routing (envoy-idle.sh) until the chart has a value
for it."""
import json
import os
import sys

import yaml


def set_idle(c, seconds):
    opts = c.setdefault("typed_extension_protocol_options", {}).setdefault(
        "envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
        {"@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
         "explicit_http_config": {"http_protocol_options": {}}})
    opts.setdefault("common_http_protocol_options", {})["idle_timeout"] = f"{seconds}s"


arm = sys.argv[1]
cm = json.load(sys.stdin)
key = next(k for k in cm["data"] if k.endswith("envoy.yaml"))
cfg = yaml.safe_load(cm["data"][key])
res = cfg["static_resources"]
cluster = next(c for c in res["clusters"] if c["name"] == "original_destination_cluster")
routes = [r for listener in res["listeners"] for fc in listener["filter_chains"]
          for f in fc["filters"] if f["name"].endswith("http_connection_manager")
          for vh in f["typed_config"].get("route_config", {}).get("virtual_hosts", [])
          for r in vh["routes"] if r.get("route", {}).get("cluster") == "original_destination_cluster"]
assert routes, "no route to original_destination_cluster"

# Instrumentation only, every arm alike: the attempt count in the JSON access
# log, so a retried request shows as attempts 2. A chart whose access log is
# not JSON (v1.0.0) is left as it is.
for listener in res["listeners"]:
    for fc in listener["filter_chains"]:
        for f in fc["filters"]:
            for al in f["typed_config"].get("access_log", []):
                fmt = al.get("typed_config", {}).get("log_format", {}).get("json_format")
                if fmt is not None:
                    fmt["attempts"] = "%UPSTREAM_REQUEST_ATTEMPT_COUNT%"

patched = [cluster["name"]]
if arm == "idle":
    # Every cluster that sends to the model servers: the one the EPP picks
    # for, and the fail-open fallback when the chart renders it.
    targets = [cluster] + [c for c in res["clusters"] if c["name"] == "inference_pool_fallback"]
    for c in targets:
        set_idle(c, os.environ.get("IDLE_S", "4"))
    patched = [c["name"] for c in targets]
elif arm == "retry":
    for r in routes:
        r["route"]["retry_policy"] = {"retry_on": os.environ.get("RETRY_ON", "reset"), "num_retries": 1}
elif arm != "chart":
    sys.exit(f"unknown arm {arm}")
cm["data"][key] = yaml.safe_dump(cfg, sort_keys=False)
for f in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(f, None)
json.dump(cm, sys.stdout)
print(f"{arm}: patched {key}, {len(routes)} route(s); clusters {patched}; cluster options "
      f"{json.dumps(cluster.get('typed_extension_protocol_options'))}; "
      f"retry {[r['route'].get('retry_policy') for r in routes]}", file=sys.stderr)
