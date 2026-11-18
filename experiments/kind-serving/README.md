# Serving control planes compared on kind: own operator, KServe, Kueue

Status: **protocol fixed, not run** (2026-11-18, D-0158 gap G3). Zero cloud
cost: kind on optim-dev, CPU only. The results become ADR 0002 ("own operator
or KServe, and where Kueue fits"), whatever they say.

## Why

Inference-platform job posts ask for "vLLM, Triton, KServe or Ray" (4 of 9
read on 2026-11-18). This platform serves models with its own operator
(vllm-coldstart-operator). The honest interview question is: *why not
KServe?* This experiment answers it with numbers instead of opinions, and
adds Kueue, the standard queue for batch work on shared accelerators.

## Fairness

Same kind node, same model (`Qwen/Qwen2.5-0.5B-Instruct`), same vLLM CPU image
by digest, same command, flags, env, readiness probe and resources in both
paths: KServe runs a custom predictor container that copies what the
operator generates (its `src/main.rs` at v0.13.0). Only the control plane
differs. The image is pre-loaded into the node once, so neither path pays
the 1.12 GB pull. One model at a time (6 GiB each).

## Hypotheses, written before the data

| # | Measure | Hypothesis |
|---|---|---|
| H1 | apply to Ready, same image already on the node | equal within 10 s: the model load dominates, not the controller |
| H2 | 20 completions, p50 | equal within 10 %: same server |
| H3 | lines of YAML a team writes | operator shorter (it fills command, probe, shm, env defaults) |
| H4 | control-plane footprint (CRDs, controllers, requests) | KServe larger (more CRDs and controllers), and needs cert-manager |
| H5 | features out of the box | KServe wins: canary rollout, autoscaling (HPA/KEDA), transformers, many runtimes, LLMInferenceService with llm-d; the operator wins on warm-Ready semantics and preemption handling (its own measured results) |
| K1 | Kueue, 6 jobs of 1 CPU from 2 teams on a 2 CPU quota | 2 running at a time, 4 queued as Workloads with **no Pending pods**, all 6 done in about 3 x 60 s, alternating fairly between teams |

## Run (on optim-dev, one command at a time)

    git pull
    bash experiments/kind-serving/run.sh up
    bash experiments/kind-serving/run.sh operator
    bash experiments/kind-serving/run.sh kserve
    bash experiments/kind-serving/run.sh kueue
    bash experiments/kind-serving/run.sh report
    bash experiments/kind-serving/run.sh down

Each phase writes `experiments/kind-serving/results/<phase>.log`. Paste the
logs back (no secrets in them: no cloud, no tokens).

Pinned versions: `versions.env` (KServe v0.21.0 in Standard mode, no Knative,
no Istio, no ingress; cert-manager v1.17.0 as KServe tests it; Kueue v0.20.6;
operator v0.13.0).

## What it does not show

- GPU behaviour, autoscaling under load, or multi-node scheduling: kind on
  one machine, CPU, one replica.
- KServe's strengths that need more pieces (Knative scale-to-zero, Istio
  canary, llm-d via LLMInferenceService) are listed, not measured.
- Kueue's value is largest with scarce GPUs and many teams; 2 CPUs and 6
  jobs only prove the mechanism.
