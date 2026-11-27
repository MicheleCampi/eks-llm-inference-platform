#!/usr/bin/env python3
"""Render the model workload of README.md as JSON for kubectl apply.

  workload.py KIND VERSION BACKEND
    KIND     rollout | deployment
    VERSION  v1 | v2-good | v2-bad
    BACKEND  vllm | stub

Every pod: Guaranteed QoS with 1 exclusive core (static CPU manager), label
`version`, readiness on /health, preStop sleep 10 s, grace 60 s. The vLLM
pins come from the environment (../prefix-routing/versions.env). The only
differences between versions are the ones README.md "Versions under test"
names: v2-good changes one environment variable, v2-bad adds
--max-num-seqs 1 (MAX_NUM_SEQS=1 on the stub)."""
import json
import os
import sys

kind, version, backend = sys.argv[1:4]
assert kind in ("rollout", "deployment") and version in ("v1", "v2-good", "v2-bad") and backend in ("vllm", "stub")
label = "v1" if version == "v1" else "v2"
extra = "--max-num-seqs 1" if version == "v2-bad" else ""

if backend == "vllm":
    # Three of these must fit Guaranteed on a 15.6 GiB runner node, next to
    # Prometheus and the control plane: 4750Mi each (4Gi crashed at start on
    # 2026-11-27, run 45964140468).
    memory = os.environ.get("VLLM_MEMORY", "4750Mi")
    container = {
        "name": "vllm",
        "image": "vllm-cpu-ci:pinned",
        "imagePullPolicy": "Never",
        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True},
        "command": ["bash", "-c"],
        # The static CPU manager gives the container one exclusive core; vLLM
        # binds its OpenMP thread to the cores the process may run on (its
        # affinity: the cgroup's cpuset file is not always visible in kind).
        "args": ["cores=$(python3 -c 'import os; c=sorted(os.sched_getaffinity(0)); "
                 "print(c[0] if len(c) == 1 else f\"{c[0]}-{c[-1]}\")'); "
                 "export VLLM_CPU_OMP_THREADS_BIND=$cores; "
                 "echo \"version $MODEL_REVISION_LABEL bound to cores $cores, extra args: '$EXTRA_ARGS'\"; "
                 "exec vllm serve \"$MODEL\" --revision \"$MODEL_REVISION\" --tokenizer-revision \"$MODEL_REVISION\" "
                 "--port 8000 --dtype bfloat16 --max-model-len 2048 $EXTRA_ARGS"],
        "env": [
            {"name": "MODEL", "value": os.environ["MODEL"]},
            {"name": "MODEL_REVISION", "value": os.environ["MODEL_REVISION"]},
            {"name": "MODEL_REVISION_LABEL", "value": label},
            {"name": "EXTRA_ARGS", "value": extra},
            {"name": "HF_HUB_OFFLINE", "value": "1"},
            {"name": "VLLM_CPU_KVCACHE_SPACE", "value": "1"},
            {"name": "VLLM_CPU_NUM_OF_RESERVED_CPU", "value": "0"},
            {"name": "VLLM_SERVER_DEV_MODE", "value": "1"},
            {"name": "VLLM_CACHE_ROOT", "value": "/tmp/vllm"},
            {"name": "TRITON_CACHE_DIR", "value": "/tmp/triton"},
            {"name": "XDG_CONFIG_HOME", "value": "/tmp/config"},
        ],
        "volumeMounts": [
            {"name": "hf", "mountPath": "/root/.cache/huggingface"},
            {"name": "shm", "mountPath": "/dev/shm"},
            {"name": "tmp", "mountPath": "/tmp"},
        ],
    }
    volumes = [
        {"name": "hf", "hostPath": {"path": "/hf-cache", "type": "Directory"}},
        {"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": "1Gi"}},
        {"name": "tmp", "emptyDir": {}},
    ]
    startup_failures = 120
else:
    memory = "128Mi"
    container = {
        "name": "vllm",
        "image": os.environ["LOADGEN_IMAGE"],
        "command": ["python3", "/stub/stub_vllm.py"],
        "env": [{"name": "MODEL_REVISION_LABEL", "value": label},
                {"name": "MAX_NUM_SEQS", "value": "1" if version == "v2-bad" else "256"}],
        "volumeMounts": [{"name": "stub", "mountPath": "/stub"}],
    }
    volumes = [{"name": "stub", "configMap": {"name": "stub-vllm"}}]
    startup_failures = 24

container.update({
    "ports": [{"name": "http", "containerPort": 8000}],
    "startupProbe": {"httpGet": {"path": "/health", "port": 8000}, "periodSeconds": 5, "failureThreshold": startup_failures},
    "readinessProbe": {"httpGet": {"path": "/health", "port": 8000}, "periodSeconds": 5},
    # The pod leaves the Service endpoints before the server stops.
    "lifecycle": {"preStop": {"sleep": {"seconds": 10}}},
    "resources": {"requests": {"cpu": "1", "memory": memory}, "limits": {"cpu": "1", "memory": memory}},
})

template = {
    "metadata": {"labels": {"app": "model", "version": label},
                 "annotations": {"prometheus.io/scrape": "true", "prometheus.io/port": "8000"}},
    "spec": {
        "terminationGracePeriodSeconds": 60,
        "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [container],
        "volumes": volumes,
    },
}
surge = {"maxSurge": 1, "maxUnavailable": 0}  # the operator's (vllm-coldstart-operator v0.18.0)

if kind == "deployment":
    obj = {
        "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "model"},
        "spec": {"replicas": 2, "selector": {"matchLabels": {"app": "model"}},
                 "strategy": {"type": "RollingUpdate", "rollingUpdate": surge}, "template": template},
    }
else:
    obj = {
        "apiVersion": "argoproj.io/v1alpha1", "kind": "Rollout", "metadata": {"name": "model"},
        "spec": {
            "replicas": 2, "selector": {"matchLabels": {"app": "model"}}, "template": template,
            "strategy": {"canary": dict(surge, steps=[
                {"setWeight": 50},
                {"analysis": {"templates": [{"templateName": "slo-ttft"}],
                              "args": [{"name": "canary-hash", "valueFrom": {"podTemplateHashValue": "Latest"}},
                                       {"name": "le", "value": os.environ.get("TB_LE", "1.0")}]}},
                {"setWeight": 100},
            ])},
        },
    }
print(json.dumps(obj))
