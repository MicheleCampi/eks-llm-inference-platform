# Experiment evidence — own operator vs KServe, and Kueue, on kind (2026-11-19)

Protocol and hypotheses: `experiments/kind-serving/README.md` (written
2026-11-18, before any run). Decision: [ADR 0002](../adr/0002-own-operator-or-kserve.md).

Machine: optim-dev, 4 cores, 7.56 GiB RAM, no GPU. kind v0.30.0, Kubernetes
v1.34.0 (one node). KServe v0.21.0 in Standard mode (no Knative, no Istio, no
ingress), cert-manager v1.17.0, operator v0.13.0, Kueue v0.20.6. Model
`Qwen/Qwen2.5-0.5B-Instruct`, vLLM CPU v0.11.2 by digest, image pre-pulled
on the node once. Cost: 0.

## Results

| Measure | Operator (path A) | KServe (path B) |
|---|---|---|
| Pod resources | requests cpu 1, memory 6Gi; limit memory 6Gi, no CPU limit | requests cpu 1, memory 6Gi; limits cpu 4 (= node cores), memory 6Gi |
| apply → Ready | 48 s | 48 s |
| 20 completions (32 tokens) | 20/20 HTTP 200, p50 2.21 s, max 17.33 s | 20/20 HTTP 200, p50 2.16 s, max 17.61 s |
| Node memory, model Ready | 5.173 GiB | 5.172 GiB |
| Objects created | Deployment, ReplicaSet, Pod, Service, **NetworkPolicy** | Deployment, ReplicaSet, Pod, Service (port 80), **HPA**; no NetworkPolicy |
| Lines a team writes | 18 | 35 |
| CRDs installed | 3 | 6 |
| Controller requests | 10m CPU, 32Mi | 2 containers x 100m CPU, 300Mi; plus cert-manager (3 deployments, no requests set) |

The max is the first, cold request in both paths.

Node memory with every control plane up and no model: 2.05 GiB.

Kueue (path C): 6 suspended Jobs of 1 CPU, 3 from `team-a` and 3 from
`team-b`, against one ClusterQueue with a 2 CPU nominal quota.
- Admitted in waves of 2: at t=1 s 2 admitted; at t=77 s 4 admitted and 2 done; at t=138 s 6 admitted and 4 done; at t=199 s 6 of 6 done.
- Never more than 2 running at once.
- 0 Pending pods after t=16 s, because the queued Jobs stay suspended in Kueue instead of waiting in the scheduler.
- ClusterQueue back to 0 usage.
- Kueue controller: 500m CPU, 512Mi requested; 11 CRDs.

## Invalid run, kept on record

KServe run 1 (19:47Z) had `limits.cpu: 1` in the manifest, while the
operator sets CPU as a request only (a CPU limit throttles the tokenizer, its
source says). The result was a p50 of 12.49 s against 2.21 s. That came from the
manifest, not from KServe, and was found by comparing the pod specs before
using the number (fix: #68). Lesson for the ADR: KServe's defaults deserve
reading, and a fair benchmark logs the real pod spec (`run.sh` now does).

## Problems met on the way (fixed in the experiment, not results)

- **ghcr.io 403 on the public KServe chart.** helm fell back to a stale login in `~/.docker/config.json`. Charts are now pulled anonymously (#66).
- **`CreateContainerError`.** `kind load docker-image` with a digest reference imports the image under `import-<date>`. The node's containerd now pulls the image itself (#67).
- **RAM check.** It first asked for 10 GiB, a guess; it now asks for 6.5 GiB, the measured need (#65, #67).

## Hypotheses

| # | Hypothesis | Result |
|---|---|---|
| H1 | apply → Ready equal within 10 s | **confirmed**: 48 s and 48 s |
| H2 | p50 equal within 10 % | **confirmed**: 2.21 s and 2.16 s (2 %) once the pods matched |
| H3 | operator spec shorter | **confirmed**: 18 lines against 35 |
| H4 | KServe control plane larger, needs cert-manager | **confirmed**: 6 CRDs and 200m/600Mi requested plus cert-manager, against 3 CRDs and 10m/32Mi |
| H5 | features: KServe wins on canary, autoscaling, runtimes, llm-d | **not measured** here (listed in the ADR); seen: KServe adds an HPA by default, the operator a default-deny NetworkPolicy |
| K1 | 2 at a time, no Pending pods, ~3 x 60 s, fair between teams | **confirmed except fairness**: 2 at a time, 0 Pending pods, 199 s; fairness not measured (one FIFO ClusterQueue, no fair sharing configured) |
