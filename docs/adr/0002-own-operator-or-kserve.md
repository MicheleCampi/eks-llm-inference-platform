# ADR 0002: Own operator or KServe for serving, and where Kueue fits

- Status: proposed (2026-11-19, D-0158 gap G3); accepted when merged
- Evidence: [kind-serving-2026-11-19](../evidence/kind-serving-2026-11-19.md),
  protocol and hypotheses in `experiments/kind-serving/README.md`, written
  before the run

## Context

This platform serves models with its own operator,
[vllm-coldstart-operator](https://github.com/MicheleCampi/vllm-coldstart-operator)
(Rust, kube-rs). KServe is the CNCF standard for model serving on Kubernetes
and appears in inference job posts. The question a reviewer asks is "why not
KServe?". The experiment answers it with the same model, image, command and
resources in both paths, so only the control plane differs.

## What the data says

- **Serving is the same.** Ready in 48 s against 48 s, p50 2.21 s against 2.16 s, the same node memory. The data plane is vLLM in both cases, and the control plane adds nothing measurable to latency or start time.
- **The difference is in the control plane:**
  - **Footprint:** the operator has 3 CRDs and requests 10m CPU and 32Mi. KServe has 6 CRDs, requests 200m and 600Mi, and needs cert-manager.
  - **Spec length:** a team writes 18 lines for the operator and 35 for KServe.
  - **Defaults:** the operator creates a default-deny NetworkPolicy, and only labelled clients reach the model. KServe creates an HPA and no NetworkPolicy, so isolation is the platform's job.
  - **Fairness pitfall:** a fair comparison needs care. The first KServe run carried a 1 CPU limit and was 5.6 times slower. Defaults, not frameworks, decide latency.
- **Not measured, from the projects' documentation:** KServe brings canary rollout, autoscaling with HPA or KEDA, transformers and explainers, many runtimes (Triton, Hugging Face, vLLM), and LLMInferenceService with llm-d for disaggregated LLM serving. The operator's own measured strengths are warm-Ready semantics (Eager warmup) and preemption handling with a make-before-break drain.

## Decision

1. **Keep the own operator** as the serving API of this platform. The serving result is the same, and the control plane is about 20 times smaller in requests and half the spec a team writes. Network isolation comes by default, and the cold-start and preemption behaviour is the reason the operator exists.
2. **Treat KServe as the planned way out, not a rewrite.** The data plane is identical, so a model moves from `VllmService` to `InferenceService` by moving the same container spec. Adopt KServe when one of these becomes true:
   - several teams need runtimes other than vLLM;
   - canary rollout or traffic splitting between model versions is needed;
   - disaggregated LLM serving (llm-d) is needed;
   - an employer standard requires it.

   On adoption, the platform adds a NetworkPolicy per InferenceService (a Kyverno generate rule) and sets explicit CPU requests and limits. Never rely on KServe's defaults.
3. **Kueue: adopt when the GPU pool opens to more than one team**, not before. It enforced a 2 CPU quota across 2 teams with no Pending pods, which keeps the scheduler and Karpenter from scaling for work that is not admitted. That matters with scarce GPUs and is idle weight today: 500m CPU and 512Mi for a platform with no batch tenants. When adopted, configure fair sharing or cohorts and measure fairness, which this run did not.

## Consequences

- An interviewer's "why not KServe?" has a measured answer: the same serving, a smaller control plane, a safer default, and a written trigger for switching.
- The operator stays a maintained dependency (Rust, kube-rs) of one author. This is the main risk of decision 1, mitigated by decision 2: the exit is cheap because the data plane is standard.
- The comparison covers one CPU node and one replica. GPU behaviour, autoscaling under load and multi-node scheduling are not covered. Those are game-day or GPU-budget questions.
