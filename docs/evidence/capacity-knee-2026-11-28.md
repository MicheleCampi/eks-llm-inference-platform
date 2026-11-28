# Experiment evidence: capacity at the SLO, the knee sweep on kind (2026-11-28)

Protocol and hypotheses: [`experiments/capacity-knee/README.md`](../../experiments/capacity-knee/README.md),
written before any run. Amendment 1 came after run 1. Workflow:
`.github/workflows/finops-guardrail.yml`, jobs 3 and 4. Cost: 0
(GitHub-hosted runners, no AWS resources).

## Run 1

[46153004325](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46153004325),
head `f08fa99`. Both jobs ran on Intel Xeon 6975P-C. The first dispatch
(46152921833) stopped at the runner check (AMD EPYC 7763, no AVX-512)
before any measurement.

| Job | Order | T | P | C | Replay (1.5 x C) | Requests per rep (premium / batch) |
|---|---|---|---|---|---|---|
| 3 | nopolicy m1 m2 m3 m4 nopolicy | 0.7 s | 0.12 s | 0.375 req/s | 0.56 req/s | 205 / 465 |
| 4 | nopolicy m4 m3 m2 m1 nopolicy | 0.9 s | 0.13 s | 1.0 req/s | 1.5 req/s | 560 / 1244 |

Job 3's C: the 0.5 req/s step had 2 misses in 30 requests (budget
6.7 %), and the 0.375 step passed. Job 4 passed 1.0 req/s (3 misses in 56,
5.4 % against the 5 % limit at 1.5 and 2.0).

| Job | Arm | Good tokens | EUR per M good tokens | Premium budget | Batch 429 | Restarts |
|---|---|---|---|---|---|---|
| 3 | nopolicy 1 / 2 | 13133 / 13196 | 4.67 / 4.65 | 1122 % / 488 % | 0 | 0 |
| 3 | m1 | 12656 | 4.85 | 927 % | 12 | 0 |
| 3 | m2 | 13255 | 4.63 | 683 % | 1 | 0 |
| 3 | m3 | 13196 | 4.65 | 829 % | 0 | 0 |
| 3 | m4 | 13257 | 4.63 | 488 % | 0 | 0 |
| **4** | nopolicy 1 / 2 | **33330 / 32460** | **1.84 / 1.89** | 3107 % / 3875 % | 0 | 0 |
| **4** | m1 | 11882 | 5.20 | 4804 % | 827 | 0 |
| **4** | m2 | 20134 | 3.07 | 2214 % | 520 | 0 |
| **4** | m3 | 25458 | 2.42 | 2518 % | 252 | 0 |
| **4** | m4 | **30340** | **2.03** | 3411 % | 62 | 0 |

Every response was a 200 or, on batch only, a 429. No request timed out
or failed.

## Hypotheses, by the written rule

| # | Job 3 | Job 4 | Verdict |
|---|---|---|---|
| H1 a knee below 4 | m\* = 1 (m1 to m2 +4.7 %) | m\* = 4 (m3 to m4 +19 %) | **refuted** |
| H2 EUR at m\* <= 1.1 x nopolicy | 4.85 vs 4.66 (1.04 x) | 2.03 vs 1.87 (1.09 x) | holds |
| H3 premium budget at m\* <= half of nopolicy | 927 % vs 805 % | 3411 % vs 3491 % | **refuted** |
| H4 restarts on record | 0 | 0 | not observed |

The rule declares the smaller m\*, so run 1 declares 1 request per
replica. That number is not a knee, for the reasons below.

## What the numbers say

1. **Job 3 measured no load, not a knee.** Same CPU as job 4, but its C
   came out 2.7 x lower because 2 misses in 30 requests decided it. At
   0.56 req/s every arm served the same good tokens within 5 %, at the
   same cost. A capacity number read off one short calibration is noise;
   the SLO and the load have to be fixed values (amendment 1).
2. **Job 4 closes the 1.71 x of step 9.** At 1.5 req/s the cost per good
   token falls as the declared capacity rises: 2.78 x the nopolicy median
   at m1, 1.64 x at m2, 1.29 x at m3, 1.09 x at m4. The guardrail's extra
   cost in D-0176 was the declared capacity, not the policy.
3. **The knee is above 4 per replica.** Good tokens were still rising by
   19 % from m3 to m4, and m4 was 8 % below nopolicy. The sweep has to go
   further (amendment 1: 4, 6, 8, 12).
4. **Holding batch back does not buy premium its TTFT here.** In job 4,
   premium TTFT p95 was about 1 s in every arm from m3 up, against
   T = 0.9 s, with batch queued in the router (queue p95 8.6 to 9.5 s).
   The premium misses come from the engine's own contention, which an
   admission gate in front of it does not remove. m2 lowered the premium
   budget by a third (2214 % against 3491 %) at 1.64 x the cost.
5. **No restarts in 12 reps.** The D-0174 restarts were not reproduced at
   this load. H4 stays open, and the capture (last state and previous log)
   is in place for the next one.

## What this does not show

The protocol's list: one model on 2 CPU cores, no GPU, request-count
capacity only. One rep per `m` and job gives a direction, not an interval.
