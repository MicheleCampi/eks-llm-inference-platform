# Capacity at the SLO: the throughput knee of a vLLM replica, on kind

Written 2026-11-28, before any code or run. Results go to
`docs/evidence/capacity-knee-<date>.md`. This file is not edited to fit
them, and any change after the first run is a dated amendment at the end.

## Question

Two earlier results had the same root, the capacity the platform declares:
- In step 8 (`docs/evidence/canary-rollback-2026-11-27.md`, D-0174), at
  60 % of capacity, requests were lost with no rollout at all, along with
  model container restarts (exit code 1).
- In step 9 (`docs/evidence/finops-guardrail-2026-11-27.md`, D-0176), the
  router's priority guardrail was configured at 1 request per replica,
  the one-at-a-time SLO point. Above capacity it cost 1.71 x per good
  token, because continuous batching serves more at the same SLO.

The question is how many requests one replica should be declared to take,
and how to read that number off a measurement rather than a guess.

## Standard first

No new component. This is the step 9 bench (`experiments/finops-guardrail`)
with one parameter, the upstream `concurrency-detector`'s `maxConcurrency`,
set to 1, 2, 3 or 4 per replica. The policy is otherwise unchanged:
- flow control on, `priority-holdback-policy` with ceilings 10 -> 1.0 and
  -10 -> 0.5;
- premium never shed, batch shed with 429 after 10 x T.

The comparison arm is the same router with no policy. The chosen number
is a value in a Helm values file in Git. That is how a platform team
declares capacity per model and per hardware.

## Set-up

The step 9 set-up, with amendments 1 and 2:
- kind on a 4-CPU runner, 2 vLLM CPU v0.34.0 replicas of 2 cores, and
  llm-d-router v1.0.0 with an InferencePool;
- the `conv` window of the Azure trace at **1.5 x C**;
- tenants premium 0.3 and batch 0.7, with the same seed.

The runner checks are unchanged: AVX-512, and AMX on Intel. CPU model and
versions are printed per job.

## Arms and sequence

| Arm | Router |
|---|---|
| `nopolicy` | chart defaults, flow control off |
| `m1` ... `m4` | the step 9 guardrail with `maxConcurrency` 1, 2, 3, 4 per replica |

Each job calibrates T, P and C, then runs:
- job 1: `nopolicy, m1, m2, m3, m4, nopolicy`;
- job 2: `nopolicy, m4, m3, m2, m1, nopolicy`.

That is one rep of each `m` per job, and two of `nopolicy`. Every
comparison stays inside one job, so n = 2 per arm across the two jobs.

## Measures

Per rep:
- good tokens per window (premium and batch, each against its own SLO, as
  in step 9);
- EUR per million good tokens;
- premium budget burned;
- batch 429s;
- model container restarts. When a container restarted, its previous log
  is saved: `kubectl logs --previous` and the last state's exit code and
  reason.

## Rule for the knee (fixed here)

In each job, **m\*** is the smallest `m` such that:
- good tokens at `m + 1` are less than 5 % above good tokens at `m`;
- or `m = 4`.

The declared capacity is m\*. If the two jobs give different m\*, the
smaller one is declared.

## Hypotheses

| # | Hypothesis |
|---|---|
| H1 | a knee exists: in each job, good tokens at m\* are at least 1.2 x good tokens at `m1`, and m\* < 4 |
| H2 | the right capacity removes the cost of the guardrail (D-0176 H2 again): in each job, EUR per million good tokens at m\* <= 1.1 x the `nopolicy` median |
| H3 | the right capacity protects premium (D-0176 H1, once, as the ROADMAP says): in each job, premium budget at m\* <= 0.5 x the `nopolicy` median |
| H4 | restarts have a cause on record (D-0174 H1): every model container restart in any rep has its exit code, reason and previous log saved. With 0 restarts, H4 is "not observed", not "holds" |

A refuted hypothesis is published as refuted.

## What this does not show

- A GPU, a different model, or long contexts. The knee is per model and
  per hardware, and this one is for Qwen2.5-0.5B on 2 CPU cores.
- Token-based capacity (`concurrencyMode: tokens`), which is the next
  candidate if the request count proves too coarse.
- Zero downtime during a rollout (ROADMAP step 7).

## Amendment 1 (2026-11-28, after run 1, before run 2)

Run 1 (workflow run 46153004325, jobs 3 and 4 of
`.github/workflows/finops-guardrail.yml`, which are jobs 1 and 2 above)
is published as it came out in `docs/evidence/capacity-knee-2026-11-28.md`.
Two things in it stop the rule from reading a knee:
- **The offered load was not the same in the two jobs.** Both ran on the
  same CPU (Intel Xeon 6975P-C). Calibration still gave C = 0.375 req/s in
  job 3 and C = 1.0 req/s in job 4, so job 3 replayed 0.56 req/s and job 4
  1.5 req/s. One rate step is 30 requests, and 2 misses at 0.5 req/s
  decided job 3's C. At 0.56 req/s every `m` served the same good tokens,
  so job 3's m\* = 1 says "no load", not "knee at 1".
- **The sweep stopped below the knee.** In job 4, good tokens rose by 19 %
  from `m3` to `m4`, and `m4` was still 8 % below `nopolicy`.

Changes, for run 2 only (jobs 5 and 6 of the workflow):
1. **The SLO and the load are fixed, not calibrated per job.** T = 0.9 s,
   P = 0.13 s and C = 1.0 req/s, job 4's values, so the replay is
   1.5 req/s in both jobs. An SLO is a contract and does not move with a
   runner. Calibration still runs, and its values are saved as
   `calib-conv.measured.json` for the record.
2. **The sweep is `m` = 4, 6, 8, 12.** Job 5 runs
   `nopolicy, m4, m6, m8, m12, nopolicy`; job 6 runs
   `nopolicy, m12, m8, m6, m4, nopolicy`.
3. **The knee rule reads "the next value in the sweep"** in place of
   `m + 1`, and "or `m` = 12" in place of "or `m` = 4". H1 compares m\*
   with `m4` and needs m\* < 12. H2 to H4 are unchanged.

Every other rule above is unchanged.
