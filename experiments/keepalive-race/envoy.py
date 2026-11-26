"""Writes the Envoy config of one arm to stdout.

The listener, route and cluster copy the `vllm` listener and the
`original_destination_cluster` of the llm-d-router-standalone chart at
llm-d-router 32a075e2 (config/charts/llm-d-router-standalone/values.yaml),
without the ext_proc filter: the client sets x-gateway-destination-endpoint
itself, as the EPP does in the chart. The failure under study happens after
the EPP has picked the pod, on the Envoy-to-model-server connection.

Arms:
  chart   as the chart: no upstream idle timeout (Envoy default 1 h), no retry
  idle    upstream idle_timeout IDLE_S (below the server's keep-alive)
  retry   route retry_policy retry_on RETRY_ON, 1 retry
Environment: IDLE_S, RETRY_ON, LISTEN_PORT, ADMIN_PORT.
"""
import json
import sys

import os

arm = sys.argv[1]
idle_s = os.environ.get("IDLE_S", "4")
retry_on = os.environ.get("RETRY_ON", "reset")
port = int(os.environ.get("LISTEN_PORT", "8081"))
admin = int(os.environ.get("ADMIN_PORT", "19000"))

access_log = [{
    "name": "envoy.access_loggers.file",
    "typed_config": {
        "@type": "type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog",
        "path": "/dev/stdout",
        "log_format": {"omit_empty_values": True, "json_format": {
            "start_time": "%START_TIME%", "status": "%RESPONSE_CODE%",
            "flags": "%RESPONSE_FLAGS%", "details": "%RESPONSE_CODE_DETAILS%",
            "duration_ms": "%DURATION%", "upstream": "%UPSTREAM_HOST%",
            "upstream_failure": "%UPSTREAM_TRANSPORT_FAILURE_REASON%",
            "attempts": "%UPSTREAM_REQUEST_ATTEMPT_COUNT%",
            "upstream_local": "%UPSTREAM_LOCAL_ADDRESS%"}}}}]

route = {"cluster": "original_destination_cluster", "timeout": "86400s",
         "idle_timeout": "86400s", "upgrade_configs": [{"upgrade_type": "websocket"}]}
if arm == "retry":
    route["retry_policy"] = {"retry_on": retry_on, "num_retries": 1}

cluster = {
    "name": "original_destination_cluster", "type": "ORIGINAL_DST",
    "connect_timeout": "1000s", "lb_policy": "CLUSTER_PROVIDED",
    "circuit_breakers": {"thresholds": [{"max_connections": 40000,
                                         "max_pending_requests": 40000,
                                         "max_requests": 40000}]},
    "original_dst_lb_config": {"use_http_header": True,
                               "http_header_name": "x-gateway-destination-endpoint"}}
if arm == "idle":
    cluster["typed_extension_protocol_options"] = {
        "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
            "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
            "common_http_protocol_options": {"idle_timeout": f"{idle_s}s"},
            "explicit_http_config": {"http_protocol_options": {}}}}

hcm = {
    "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
    "stat_prefix": "http-8081",
    "route_config": {"name": "vllm", "virtual_hosts": [{
        "name": "vllm-default", "domains": ["*"],
        "routes": [{"match": {"prefix": "/"}, "route": route}]}]},
    "http_filters": [{"name": "envoy.filters.http.router", "typed_config": {
        "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router",
        "suppress_envoy_headers": True}}],
    "use_remote_address": True, "normalize_path": True, "merge_slashes": True,
    "server_header_transformation": "PASS_THROUGH",
    "common_http_protocol_options": {"headers_with_underscores_action": "REJECT_REQUEST"},
    "path_with_escaped_slashes_action": "UNESCAPE_AND_REDIRECT",
    "access_log": access_log}

cfg = {
    "admin": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": admin}}},
    "static_resources": {
        "listeners": [{
            "name": "vllm",
            "address": {"socket_address": {"address": "0.0.0.0", "port_value": port}},
            "per_connection_buffer_limit_bytes": 32768,
            "filter_chains": [{"name": "vllm", "filters": [{
                "name": "envoy.filters.network.http_connection_manager",
                "typed_config": hcm}]}]}],
        "clusters": [cluster]}}
json.dump(cfg, sys.stdout, indent=1)
