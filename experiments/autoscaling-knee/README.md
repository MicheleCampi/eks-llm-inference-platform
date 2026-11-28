# Autoscaling at the measured capacity: KEDA on requests in flight, on kind

Written 2026-11-28, before any code or run. Results go to
`docs/evidence/autoscaling-knee-<date>.md`. This file is not edited to fit
them, and any change after the first run is a dated amendment at the end.

## Question

Step 6 (`docs/evidence/capacity-knee-2026-11-28.md`, D-0181) measured the
throughput knee of one vLLM replica: 4 to 6 requests in flight, declared at
4. The ROADMAP (step 6b) asks for an autoscaler with that number as its
target.

That is a capacity, not a scaling target. A replica holds 4 requests in
flight only when it is saturated, so at a load it still serves inside the
SLO it holds fewer. An HPA that divides the requests in flight by 4 will
then ask for fewer replicas than the load needs, until the queue grows back.
Little's law gives the other candidate: the requests in flight a replica
holds at the load it is meant to carry (rate x time in the system).

The question is which of the two to give the autoscaler, and what scaling
saves against a pool sized for the peak, on a real vLLM replica that takes
minutes to become Ready.

## Standard first

No new component of our own:
- **KEDA 2.21.0** (chart by SHA-256, images by digest, the pins of
  vllm-coldstart-operator's CI). It creates the HPA.
- **A `prometheus` trigger** on vLLM's own gauges,
  `vllm:num_requests_running + vllm:num_requests_waiting`, summed over the
  pods and averaged over 1 minute. This is the signal of the operator's
  scale-out example (`deploy/examples/keda/scaledobject-scale-out.yaml`),
  here read from real vLLM.
- **HPA behaviour:**
  - scale-up stabilization 0 s;
  - scale-down stabilization 300 s (the Kubernetes default);
  - KEDA polling interval 15 s.
- **The target is the vLLM StatefulSet of steps 6 to 9.** Each replica has
  its own 2 cores, and the llm-d-router v1.0.0 InferencePool picks up a pod
  when it is Ready. The router runs with flow control off (the `nopolicy`
  arm of step 6).

The operator's own scaling path (KEDA to a `FleetService` through its scale
subresource) is the same HPA on the same signal. Here KEDA targets the
StatefulSet, so the operator is not part of this bench. The question is the
target value, and it is the same for both.

## Set-up

- kind on a 4-CPU runner, **Intel Xeon 6975P-C only**: the SLO below was
  measured on that CPU (D-0181), and any other runner stops at the runner
  check.
- vLLM CPU v0.34.0 and Qwen2.5-0.5B-Instruct, as in steps 6 to 9. Between
  1 and 2 replicas of 2 cores each: the runner has 4 CPUs, so **2 is the
  most this bench can show**.
- Prometheus v3.15.0 in the cluster (one replica, 5 s scrapes, test
  infrastructure), and KEDA. They run in every arm, including the static
  one.

### SLO (fixed, D-0181)

- T = 0.9 s (TTFT) and P = 0.13 s (TPOT), measured on this CPU.
- Good request: a 200 with TTFT <= T and TPOT <= P.
- Error budget 1 % of requests, as in step 7. Budget burned = bad fraction
  / 1 %.

### Load (fixed): a step on the trace

The `conv` window of the Azure trace (step 7) is too flat to scale on: its
busiest minute is 1.22 x the window's mean. The load is therefore a step,
the standard autoscaling test, built from the same window. The arrival
times and lengths come from the trace, thinned with the step 7 seed to:

| Segment | Offset | Mean rate | Meaning |
|---|---|---|---|
| low | 0-300 s | 0.3 req/s | 0.6 x the capacity of one replica (C = 1.0 req/s for two, D-0181) |
| high | 300-900 s | 1.0 req/s | the capacity of two replicas |
| low | 900-1200 s | 0.3 req/s | back to the first level |

## Arms

| Arm | Replicas | KEDA threshold (requests in flight per replica) |
|---|---|---|
| `static2` | 2, fixed | none: the pool sized for the peak, as in steps 6 to 9 |
| `knee` | 1 to 2 | **4**, the capacity declared in D-0181 |
| `little` | 1 to 2 | **L**, measured in the job by the rule below |

Each autoscaled arm starts from 1 Ready replica, and `static2` from 2.

**Rule for L (fixed here).** Before the arms, with 1 replica and the router:
1. replay 180 s of Poisson arrivals at **0.35 req/s**, with lengths from
   the window. That is 70 % of one replica's capacity, a common HPA
   utilisation target.
2. L = the mean of `vllm:num_requests_running + vllm:num_requests_waiting`
   over the replay, read from Prometheus. This is Little's law measured, not
   computed.
3. L is rounded to 2 decimals and written to `results/little.json`.

Jobs, one rep of each arm per job:
- job 1: `static2, knee, little`;
- job 2: `little, knee, static2`.

## Measures

Per rep, from the replay and from a sampler that reads, every 5 s, the
model pods (existing and Ready) and the HPA's desired replicas and metric:
- requests, good requests, and budget burned over the window and per
  segment;
- good tokens;
- **replica-seconds**: model pods existing, Ready or not, which is what a
  node is paid for;
- EUR per million good tokens: replica-seconds x the step 7 reference price
  of 0.1067 USD per 2-vCPU replica-hour, at 0.86 EUR/USD;
- **scale-up time**: from the start of the high segment to the second
  replica Ready, and from the HPA asking for 2 to Ready;
- the share of the high segment with 2 Ready replicas;
- the number of scale-downs in the high segment;
- model container restarts (previous log, exit code and reason saved, as in
  step 6).

## Hypotheses

Each must hold in both jobs.

| # | Hypothesis |
|---|---|
| H1 | **the knee is not a scaling target:** in `knee`, the pool has 2 Ready replicas for less than 50 % of the high segment, and the high segment burns at least 2 x the budget of `static2` |
| H2 | **Little's target holds the SLO:** in `little`, 2 Ready replicas for at least 70 % of the high segment, and whole-window budget burned <= 2 x `static2` |
| H3 | **scaling saves money:** in `little`, EUR per million good tokens <= 0.9 x `static2` |
| H4 | **scale-up is fast enough to matter:** in `little`, the second replica is Ready within 240 s of the start of the high segment |

A refuted hypothesis is published as refuted.

## What this does not show

- More than 2 replicas, so no overshoot above 2, and no comparison with the
  operator's count of warming replicas (that needs a third replica to
  overshoot into).
- Node provisioning (Karpenter): the cores of an absent replica stay on the
  runner. Replica-seconds stand in for the cost of nodes.
- A GPU, another model, a burst shorter than the cold start, or
  scale-to-zero.
