# Experiment evidence: capacity at the SLO, the knee sweep on kind (2026-11-28)

Protocol and hypotheses: [`experiments/capacity-knee/README.md`](../../experiments/capacity-knee/README.md),
written before any run. Amendment 1 came after run 1. Workflow:
`.github/workflows/finops-guardrail.yml`, jobs 3 and 4 (run 1) and 5 and 6
(run 2, amendment 1). Cost: 0
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

## Run 2 (amendment 1: fixed SLO, sweep 4 to 12)

Jobs 5 and 6, both on Intel Xeon 6975P-C, with T = 0.9 s, P = 0.13 s and
C = 1.0 req/s fixed, so 1.5 req/s and 560 / 1244 requests per rep in both:
- job 6: [46165471436](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46165471436), head `95c7c18`;
- job 5: [46166478792](https://github.com/MicheleCampi/eks-llm-inference-platform/actions/runs/46166478792), head `2572403`. Its first try in 46165471436 got an AMD EPYC 9V74 and stopped in calibration, before any arm. 2572403 adds only the runner check that pins jobs 5 and 6 to this CPU.

Calibration still ran for the record, and gave C = 0.5 req/s in both jobs
(T = 0.7 s). On one CPU model it has now given 0.375, 1.0, 0.5 and 0.5.

| Job | Arm | Good tokens | EUR per M good tokens | Premium budget | Batch 429 | Batch queue p95 | Restarts |
|---|---|---|---|---|---|---|---|
| 5 | nopolicy 1 / 2 | 32169 / 32472 | 1.91 / 1.89 | 3893 % / 3821 % | 0 | n/a | 0 |
| 5 | m4 | 29913 | 2.06 | 3821 % | 77 | 8.8 s | 0 |
| 5 | **m6** | **32685** | **1.88** | 3536 % | 0 | 3.2 s | 0 |
| 5 | m8 | 33131 | 1.86 | 3429 % | 0 | 0.6 s | 0 |
| 5 | m12 | 31088 | 1.98 | 4518 % | 0 | 0 s | 0 |
| 6 | nopolicy 1 / 2 | 32906 / 33013 | 1.87 / 1.86 | 3411 % / 3250 % | 0 | n/a | 0 |
| 6 | **m4** | **31833** | **1.93** | 2911 % | 44 | 8.0 s | 0 |
| 6 | m6 | 32850 | 1.87 | 3321 % | 0 | 2.7 s | 0 |
| 6 | m8 | 32137 | 1.91 | 3893 % | 0 | 0.8 s | 0 |
| 6 | m12 | 31682 | 1.94 | 4143 % | 0 | 0 s | 0 |

### Hypotheses, by the amended rule

| # | Job 5 | Job 6 | Verdict |
|---|---|---|---|
| H1 a knee, >= 1.2 x m4 and m\* < 12 | m\* = 6 (m4 to m6 +9.3 %, m6 to m8 +1.4 %), 1.09 x m4 | m\* = 4 (m4 to m6 +3.2 %) | **refuted** |
| H2 EUR at m\* <= 1.1 x nopolicy | 1.88 vs 1.90 (0.99 x) | 1.93 vs 1.87 (1.03 x) | holds |
| H3 premium budget at m\* <= half of nopolicy | 3536 % vs 3857 % | 2911 % vs 3330 % | **refuted** |
| H4 restarts on record | 0 | 0 | not observed |

The rule declares the smaller m\*: **4 requests per replica**.

## What the two runs say together

1. **The knee is between 4 and 6 requests per replica** for Qwen2.5-0.5B
   on 2 cores at this SLO. Read across both runs on one CPU and one fixed
   load: good tokens were 11882 at m1 (run 1, job 4), about 30000 to 32000
   at m4, and level from m6 up (32685 and 32850, against a nopolicy median
   of 32320 and 32960). H1 as written is refuted: run 1's sweep stopped
   below the knee, and the amended H1 measures from m4, which is already
   near it. The amended H1 was badly chosen, and it stays as written.
2. **At the declared capacity the guardrail costs nothing.** H2 held in
   all four jobs. At m4 it cost 1.03 to 1.09 x the nopolicy median and
   shed 3 to 6 % of batch with 429. From m6 up it cost 0.98 to 1.04 x and
   shed nothing. The 1.71 x of D-0176 came from declaring 1 request per
   replica.
3. **The capacity cannot be read off a short calibration.** The same CPU
   model gave C = 0.375, 0.5, 0.5 and 1.0 req/s. A declared capacity has to
   come from a sweep at a fixed SLO and a fixed load, as here, and has to
   be measured again for each model and each hardware.
4. **Router admission does not protect premium on this pool.** H3 was
   refuted in all four jobs. Premium TTFT p95 was about 1 s in every arm
   at or above m4, against 0.9 s, whether batch waited in the router
   (m4, queue p95 8 to 9 s) or not (m12). The misses come from requests
   that are already inside the engine. Holding batch back only helps when
   the cap is so low that it throws away throughput (m2 in run 1: premium
   budget down a third, at 1.64 x the cost). Protecting premium needs
   priority inside the engine, or a separate pool, and not a gate in
   front of the engine.
5. **No restarts in 24 reps.** The D-0174 restarts did not appear at this
   load. H4 stays "not observed", and the capture is in place.

## What this does not show

The protocol's list: one model on 2 CPU cores, no GPU, request-count
capacity only. One rep per `m` and job gives a direction, not an interval. Run 1 and
run 2 are compared only where the CPU, SLO and load match (run 1, job 4).
