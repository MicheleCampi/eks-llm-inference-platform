# Zero-downtime model rollout: canary with automatic rollback on the SLO, on kind

Written 2026-11-27, before any code or run. Results go to
`docs/evidence/canary-rollback-<date>.md`; this file is not edited to fit them.
Any change after the first run is a dated amendment at the end. Tool choice:
[ADR 0003](../../docs/adr/0003-canary-rollout-tool.md).

## Question

"How do you ship a new model or vLLM version without downtime, and what
happens when the new version is bad?" Under the replayed production-shaped
traffic of `experiments/trace-replay` (ROADMAP step 7):

1. Does the rollout drop requests (zero downtime), for a good and a bad
   version?
2. Does a canary with analysis on the SLO stop a bad version by itself, and
   how fast?
3. How much error budget does that save, compared with the rolling update
   the platform's own operator does today (`maxSurge 1`, `maxUnavailable 0`,
   no analysis: vllm-coldstart-operator v0.18.0, `src/main.rs`)?
4. Does the analysis leave a good version alone (no false rollback)?

## Set-up

- One kind node on a GitHub-hosted runner (4 CPUs), kubelet with the
  **static CPU manager policy** and 1 CPU reserved for the system: every
  vLLM pod is Guaranteed QoS with **1 exclusive core**, so the 2 stable pods
  and the 1 surge pod of a rollout never share a core. Prometheus, the
  rollout controller and the replayer share the reserved core.
- vLLM CPU v0.34.0, Qwen2.5-0.5B-Instruct at the pinned commit
  (`../prefix-routing/versions.env`), `--max-model-len 2048`, default KV cache,
  2 replicas behind a ClusterIP Service (kube-proxy). No router: this
  experiment is about the rollout, and step 7 showed the router does not help
  unique prompts.
- **Argo Rollouts v1.10.2** (latest release, read 2026-11-27), canary
  without a traffic router: the split is the ratio of pods behind the
  Service. **Prometheus v3.16.0** scrapes every vLLM pod's `/metrics` every
  10 s.
- Readiness on `/health`; `terminationGracePeriodSeconds` 60 and a `preStop`
  sleep of 10 s, so that a pod leaves the Service endpoints before vLLM stops.
  The same values in every arm.
- Traffic: the conv window of `experiments/trace-replay` (same pinned CSV,
  same scaling rules), replayed open loop at 0.6 x C, with C measured on the
  same runner at the start of the job.

## Versions under test

- **v1 (stable):** the set-up above.
- **v2-good:** v1 with one environment variable changed in the pod template
  (`MODEL_REVISION_LABEL=v2`). A new revision, the same server: it tests the
  rollout mechanics, not a better model.
- **v2-bad:** v1 with `--max-num-seqs 1`, one wrong value in a values file:
  the server answers every request, one at a time, so under a burst the queue
  and TTFT grow. A realistic regression that a health check does not see.

## Arms

Every arm is one job on its own runner; each job measures its own baseline,
so arms are compared through their ratio to it, never across runners with
different CPUs (step 7: the CPU changed the calibrated SLO 6 x).

| Arm | Workload | New version | Strategy |
|---|---|---|---|
| `good-canary` | Argo Rollout | v2-good | canary with analysis |
| `bad-canary` | Argo Rollout | v2-bad | canary with analysis |
| `bad-rolling` | Deployment | v2-bad | RollingUpdate `maxSurge 1`, `maxUnavailable 0` (the operator's) |

Canary steps (fixed here): `setWeight: 50` (1 of 2 pods on the new version,
after a surge pod is Ready; same surge settings as the Deployment), then an
**analysis step**: 8 measurements every 30 s, the first 60 s after the step
starts (so that the canary pod has served requests), then `setWeight: 100`.
A failed analysis aborts the rollout: Argo Rollouts scales the canary to 0
and the stable pods back to 2.

Sequence in each job: calibrate (T, P, C as in step 7), then **baseline**
(replay, no rollout), **arm rep 1**, **arm rep 2**, **baseline**. In an arm
rep the rollout is started 240 s into the 20-minute replay, before the
busiest minute (the window is centred on it); between reps the workload is
reset to v1 and every pod is Ready again.

## SLO, analysis and measures (fixed here)

- **SLI and objective:** as step 7. A request is good if it completes
  without error, TTFT <= T and TPOT <= P; objective 99 %; T = 2 x TTFT p95 and
  P = 2 x TPOT p95 of a closed-loop run on v1.
- **Analysis (Argo Rollouts AnalysisTemplate, Prometheus provider):** the
  fraction of the **canary pods'** requests with TTFT at or under T_b, over
  the last 2 minutes, from vLLM's own histogram
  (`vllm:time_to_first_token_seconds`); T_b is the smallest bucket boundary
  of that histogram at or above T, read from `/metrics` and written in the
  report. Measured every 30 s. **Success:** the fraction is at least
  **0.856**, a burn rate of at most 14.4 x on a 99 % objective (the
  fast-burn paging threshold of the Google SRE workbook). **Abort:** 2
  failed measurements (`failureLimit: 1`); no data is a failed measurement.
  TPOT is in the client SLI but not in the analysis: the server histogram
  of time per output token has no boundary matched to P on every runner, and
  the bad version fails on TTFT first. Said here so that it is not found later.
- **Measures:** requests failed (HTTP error or connection error); error
  budget burned over the whole replay and over the span from rollout start to
  the end of the replay; time from rollout start to the canary pod Ready, to
  the abort, and to the stable version serving alone again (bad-canary) or to
  100 % new version (others), from the Rollout's and Deployment's status.

## Hypotheses

| # | Hypothesis | Arms |
|---|---|---|
| H1 | zero downtime: 0 failed requests in every rep of every arm, rollback included | all |
| H2 | automatic rollback: bad-canary aborts within 5 minutes of the canary pod becoming Ready, and only v1 pods serve again within 7 minutes of it, in both reps, without a person | bad-canary |
| H3 | bounded damage: from rollout start to the end of the replay, bad-canary burns at most half the error budget that bad-rolling burns over the same span, both taken as the excess over their own job's baseline (same span) | bad-canary vs bad-rolling |
| H4 | no false rollback: good-canary is promoted in both reps, and its budget burned over the span is at most 1.5 x its baseline's | good-canary |

A refuted hypothesis is published as refuted.

## What this does not show

- A GPU rollout or a real new model: the regression is a configuration
  value, and v2-good is the same server.
- Rollout of the platform's operator-managed services: the experiment uses
  an Argo Rollout and a Deployment directly. How the operator hands its
  Deployment to Argo Rollouts is in ADR 0003, Consequences.
- Low-traffic analysis: at about 0.1 req/s on the canary pod a 2-minute
  window holds about a dozen requests; the threshold is a burn rate, not a
  statistical test.
- An upgrade of Kubernetes or EKS itself: that is the live part of ROADMAP
  step 8, separately budgeted.

## Amendments
