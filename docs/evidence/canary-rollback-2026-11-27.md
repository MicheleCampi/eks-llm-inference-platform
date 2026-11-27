# Experiment evidence: canary with automatic rollback on the SLO, on kind (2026-11-27)

Protocol and hypotheses: [`experiments/canary-rollback/README.md`](../../experiments/canary-rollback/README.md),
written before any code or run. Amendment 1 came before the first valid run.
Amendments 2 and 3 came after runs 1 and 2, and change only the set-up,
the sequence and the runner rule. Tool choice:
[ADR 0003](../adr/0003-canary-rollout-tool.md). Workflow:
`.github/workflows/canary-rollback.yml`. Cost: 0 (GitHub-hosted runners, no
AWS resources).

Set-up: one kind node, static CPU manager, 1 exclusive core per vLLM pod.
vLLM CPU **v0.34.0**, Qwen2.5-0.5B-Instruct, eager mode, 512 MiB KV cache,
2 replicas behind a Service, startup probe = one real 16-token completion.
**Argo Rollouts v1.10.2** runs a canary without a traffic router (the
split is the pod ratio): setWeight 50, then an analysis step, then 100.
The analysis measures the fraction of the canary pods' requests with
TTFT <= T_b over 2 minutes, every 30 s, 8 times. It passes at >= 0.856
(burn rate <= 14.4x) and aborts after 2 failed measurements.
**Prometheus v3.16.0** scrapes the pods. The comparison arm is a Deployment
rolling update with `maxSurge 1`, `maxUnavailable 0`, the strategy of
vllm-coldstart-operator v0.18.0. Traffic is the `conv` window of
`experiments/trace-replay`, replayed open loop at 0.6 x C. The rollout starts
240 s into a 20-minute replay.

v2-good is v1 with one environment variable changed. v2-bad is v1 with
`--max-num-seqs 1`: health checks pass, but under a burst TTFT grows.

## Runs

| Run | Head | Layout | Runner CPU | Status |
|---|---|---|---|---|
| [45972564757](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45972564757) (run 1) | `7fdee8d` | one job per arm, 2 reps each | bad-rolling: AMD EPYC 9V45; bad-canary, good-canary: Intel Xeon 6975P-C | valid; H3 not comparable (amendment 2) |
| [45987679316](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45987679316) (run 2, job 2) | `d90d6b7` | every arm in one job, order bad-rolling, bad-canary, good-canary | Intel Xeon 6975P-C | **valid** |
| [45987792601](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/45987792601) (run 2, job 1) | `d90d6b7` | every arm in one job, order good, bad canary, bad rolling | Intel Xeon Platinum 8573C, no AMX exposed | published below; excluded by amendment 3 |
| [46007690612](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46007690612) (run 2, job 1 again) | `41546b6` | as job 1 | Intel Xeon 6975P-C | **valid** |

Runner guards stopped two jobs before any measurement: one AMD EPYC 7763
without AVX-512 in run 1, and the first job 1 of run 2. Those jobs were run
again. The verdicts below come from run 2's two valid jobs, one rep of each
arm per job, as amendment 2 sets out.

## Calibration

| Job | T | P | C | Replay mean | T_b | Requests per replay |
|---|---|---|---|---|---|---|
| run 2 job 2 | 1.0 s | 0.17 s | 3.0 req/s | 1.8 req/s | 1.0 s | 2148 |
| run 2 job 1 (again) | 1.1 s | 0.19 s | 1.5 req/s | 0.9 req/s | 2.5 s | 1081 |
| run 2 job 1 (8573C) | 26.8 s | 0.21 s | 0.094 req/s | 0.056 req/s | 40 s | 81 |

The two valid jobs ran on the same CPU model and calibrated C two times
apart (3.0 and 1.5 req/s). The capacity step uses 60-second Poisson runs of
the step 7 ladder. That variance is the reason every comparison stays
inside one job.

## Results, run 2 (valid jobs)

Budget burned is the error budget used over the span from the rollout start
to the end of the replay, as a percentage of the 1 % budget. The baseline is
the median of the job's two baselines.

| Job | Arm | Failed requests | Budget (span) | Excess over baseline | Canary Ready | Abort after Ready | v1 only after Ready | All v2 | Min pods serving | Restarts |
|---|---|---|---|---|---|---|---|---|---|---|
| job 2 | baseline 1 / 2 | 40 / 32 | 726 % / 626 % | (676 %) | | | | | | 3 / 2 |
| job 2 | bad-canary | 110 | 1743 % | **+1067 points** | 160 s | **90 s** | **315 s** | | 1 | 5 |
| job 2 | bad-rolling | 230 | 8307 % | **+7632 points** | 103 s | | | 284 s | 2 | 1 |
| job 2 | good-canary | 6 | 3524 % | +2848 points | 101 s | | | 545 s (promoted) | 1 | 2 |
| job 1 | baseline 1 / 2 | 0 / 0 | 33 % / 143 % | (88 %) | | | | | | 0 / 0 |
| job 1 | bad-canary | 0 | 1392 % | **+1304 points** | 108 s | **90 s** | **203 s** | | 2 | 1 |
| job 1 | bad-rolling | 0 | 7768 % | **+7680 points** | 87 s | | | 206 s | 2 | 1 |
| job 1 | good-canary | 0 | 2055 % | +1967 points | 100 s | | | 480 s (promoted) | 2 | 1 |

The analysis measured these values:
- bad-canary: 0.031 and 0.02 (job 2), and 0.60 and 0.65 (job 1). Both
  failed and both aborted.
- good-canary, job 2: 0.94, 0.96, 0.98, 1, 0.99, 0.99, 0.99, 0.99.
- good-canary, job 1: 0.94, 0.96, 0.95, 0.84, 0.86, 0.87, 0.88, 1.
- Both good-canary runs were promoted.

Per pod, the fraction of requests at or under T_b, from Prometheus over the
replay:
- bad-rolling: the v2 pods answered 0 % and 1 % (job 2), and 45 % and 1 %
  (job 1). Once the rolling update finished, every request went to v2-bad
  for the rest of the replay.
- bad-canary: the one v2 pod answered 1 % (job 2) and 21 % (job 1), for
  4 to 5 minutes, and then it was gone.

## Hypotheses (run 2)

| # | Verdict | Evidence |
|---|---|---|
| H1 zero downtime | **refuted** | job 2: 110 (bad-canary), 230 (bad-rolling) and 6 (good-canary) failed requests, with 40 and 32 in its baselines and v1 restarts in both baselines. Job 1: 0 failed requests in every rep. |
| H2 automatic rollback | **holds** | abort 90 s and 90 s after the canary pod was Ready (limit 300 s); v1 only after 315 s and 203 s (limit 420 s); no person involved. Run 1 also held (89 s and 89 s). |
| H3 bounded damage | **holds** | inside each job, bad-canary's excess budget was 14 % (job 2) and 17 % (job 1) of bad-rolling's (limit 50 %) |
| H4 no false rollback | **refuted** | promoted in both reps, with no false rollback in run 2. But the span budget was 3524 % against a limit of 1014 %, and 2055 % against a limit of 132 %. Run 1 also had one false rollback (analysis 0.68, 0.735). |

## Earlier runs, published as recorded

**Run 1** had one job per arm. H2 held: abort 89.5 s and 88.7 s after
Ready, v1 only after 248 s and 319 s. H1 was refuted: bad-canary lost 93
and 116 requests, mostly 200 responses with no first chunk, from requests
queued on the killed canary pod. H4 was refuted: one false rollback, and the
promoted rep burned 1901 % against a baseline of 166 %. bad-rolling landed
on an AMD EPYC 9V45 at 0.225 req/s, where v2-bad was not bad (165 %
against baselines of 289 % and 331 %). bad-canary ran at 1.8 req/s on
Intel, so H3 could not be judged. That led to amendment 2.

**Run 2, job 1 on the 8573C** (no AMX exposed): TTFT p95 one at a time was
13.4 s, against 1.1 s on the 6975P-C. Each replay held 81 requests.
- No version was bad at 0.056 req/s, so both canaries were promoted and
  every analysis measured 1.
- Baselines burned 2346 % and 2593 % (24 % of requests over the SLO, mostly
  TPOT).
- Its own verdicts: H2 refuted (no abort), H3 refuted, H4 holds.
- It shows the protocol's limit, not the canary's: an analysis on the error
  budget cannot see a capacity regression at a load where the regression
  does not show. That led to amendment 3.

## What the numbers say

1. **The canary stops a bad version by itself, fast and every time.** Under
   a production-shaped burst, Argo Rollouts aborted v2-bad about 90 s after
   the canary pod was Ready, in 4 of 4 reps across two runs, with no person
   involved. Inside the same job, the canary did 14 to 17 % of the rolling
   update's damage. The rolling update kept v2-bad in service until the end
   of the replay. Nothing in the operator's rolling update would have
   stopped it.
2. **Zero downtime was not shown, and the cause is the platform under the
   rollout, not the rollout tool.** On the job with 0.6 x C = 1.8 req/s,
   requests also failed in the baselines with no rollout at all. They went
   with v1 container restarts. In the job at 0.9 req/s every rep had 0
   failed requests, rollbacks included.
   - Model containers that restarted exited with code 1, not OOMKilled.
   - Each rep of job 1 had exactly one restart, in a pod that started while
     three vLLM pods shared the 4-vCPU node.
   - Run 1's failures were requests queued on a canary pod when it was
     killed. vLLM drops them, and a 60 s grace period and a 10 s preStop do
     not drain them.
   The next fix is to read the restarted container's previous log, and to
   drain in-flight requests on abort.
3. **A good version still costs error budget during the rollout.** The
   per-pod data shows why the analysis passed while the client SLO burned.
   The v2 pods served almost all requests at or under T_b (2.5 s in job 1),
   while the client SLO counts TTFT > T = 1.1 s and TPOT > P as bad. While
   three pods share the node, each pod is slower. The analysis bucket
   (T_b >= T) and the missing TPOT check are a gap the protocol had already
   named. H4's limit of 1.5x baseline is tighter than this node can meet
   with a surge pod.

## What this does not show

The list is the protocol's: no GPU, no real new model, an Argo Rollout and a
Deployment instead of the operator's own services, a burn-rate threshold
rather than a statistical test, and no Kubernetes or EKS upgrade (the live
part of ROADMAP step 8, budgeted separately). Two valid reps per arm are
also too few to give an interval. They give a direction (H2 and H3 the same
in every rep) and a list of causes to fix (H1 and H4).
