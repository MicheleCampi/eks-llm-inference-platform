# Game day #1: incident response on the EKS inference platform

Status: **designed, not run**. Written with the nodes off (D-0158, 2026-11-18).
It runs as live #5, only after its own BUDGET entry and an explicit go from
the operator. Results go to `docs/evidence/gameday-<date>.md` and one
blameless postmortem per scenario (`postmortem-template.md`).

Why: the live sessions so far proved that the platform *works* (provisioning,
Spot interruption, drift, a model served on 2026-11-18). They did not prove
that a person *detects, responds to and learns from* a failure that hurts a
user. That is what on-call is, and what this repository has not shown. The
format follows common practice for game days (AWS Well-Architected REL12,
Google SRE "Disaster Role Playing", Principles of Chaos Engineering):
steady state and hypothesis written first, a small blast radius, abort
criteria, roles, a timeline, and a postmortem whose action items become
pull requests.

## 1. The service under test and its SLO

Service: `qwen-0-5b-cpu` (VllmService, `tests/live/inference-cpu.yaml`),
**2 replicas** on pool `general`, one per Spot `m7i-flex.large` node, behind
the ClusterIP Service the operator creates. A CPU model: a functional
service, not a performance benchmark (the Free Plan account has no GPU,
README Findings #1).

The SLO reuses the policy of the operator
([slo-policy.md](https://github.com/MicheleCampi/vllm-coldstart-operator/blob/v0.13.0/docs/slo-policy.md)):
the same success objective, and a latency objective recalibrated for CPU,
because the GPU objectives (TTFT 1 s, TPOT 100 ms) mean nothing here.

| SLI (measured at the client, see section 3) | Objective | Window | Budget | Calibration |
|---|---|---|---|---|
| Availability: probe requests answered HTTP 200 | 99.5 % | 30 days | 216 min of total outage | operator SLO policy |
| Latency: 32-token completions answered within 8 s | 95 % | 30 days | 5 % of requests | live #4: p50 3.83 s, cold first request 19.17 s; Docker pre-check 3.9 to 4.1 s warm ([evidence](../evidence/live-2026-11-18.md)) |

A game day lasts minutes, not 30 days. Each scenario reports the SLI over
its own window **and** the share of the 30-day budget it consumed, so that
"we lost 40 s of availability" reads as "0.3 % of the month's budget".

## 2. Roles

| Role | Who | Does |
|---|---|---|
| Incident commander and operator | Michele | Starts each scenario, decides, runs every command that changes the cluster, declares the end of the incident |
| Scribe and analyst | AI agent | Keeps the timeline with UTC times, reads logs and events the operator pastes, proposes hypotheses; changes nothing |

One terminal, one command at a time (project rule). The scribe never
receives secrets or account ids: the operator masks them before pasting.

## 3. Measuring from the user's side

A probe Deployment in `inference-test` (labelled
`inference.michelecampi.dev/client: qwen-0-5b-cpu`, so the NetworkPolicy the
operator creates admits it) sends one 32-token completion every 2 s through
the Service and writes one JSON line per request (UTC time, HTTP code,
latency). After each scenario the operator saves its log; a script computes
both SLIs and the budget consumed.

Black-box measurement at the client is the standard SLI for availability:
it sees requests lost before a replica, which vLLM's own `/metrics` cannot
(slo-policy.md, "What the objectives do not see").

Prerequisite pull request (PR B, before the BUDGET entry), each item with a
CI check:

1. `tests/gameday/probe.yaml` and `scripts/gameday-sli.py` (with a unit test
   on a fixture log).
2. A PodDisruptionBudget for the 2 replicas, `minAvailable: 1`, in
   `tests/live/inference-cpu.yaml`. Required: the operator v0.13.0 creates no
   PDB, so the Kyverno policy `require-pdb` would **deny** its Deployment at 2
   replicas. Found while designing this plan, not live.
3. Alerts in `observability/` with promtool tests: crash-looping pod
   (`kube_pod_container_status_restarts_total`) and Deployment with fewer
   available replicas than desired for 5 minutes
   (`kube_deployment_status_replicas_available`), both added to the Alloy
   allow-list. Today no alert covers either. The second also closes a gap
   found while designing S3: `KarpenterControllerDown` is `up == 0` on
   targets discovered from the Service endpoints, so a controller **scaled
   to 0** leaves no target, no `up` series and no page (a crashing pod
   stays a target and does page). `absent()` stays out, as the rules file
   explains: after a destroy it would page forever.
4. The Grafana remote-write secret step of `live.md` is in scope this time:
   detection is part of the test.

## 4. Scenarios

Run in this order; each starts only when the previous one has recovered
and the probe has been at 100 % for 5 minutes (steady state).

### S1. Spot interruption under load

- **Inject**: `tests/live/spot-interruption.sh` on the node of one replica
  (the warning on Karpenter's real SQS queue, as live #3).
- **Hypothesis**: the other replica keeps serving; at most the requests in
  flight on the drained pod fail (2 or fewer); the replacement replica is
  Ready within 4 minutes (node ~55 s, image ~60 s, model ~120 s); the PDB
  never allows 0; `KarpenterSpotInterruption` opens a ticket.
- **Pass**: availability over the window at least 99.5 %; latency SLI met
  (one replica holds the probe's rate).
- **Abort**: both replicas not Ready for more than 2 minutes.

### S2. A bad change: the live #3 defect, re-introduced on purpose

- **Inject**: `kubectl patch` the VllmService to remove
  `VLLM_CPU_KVCACHE_SPACE` (KV cache back to 4 GiB: the OOMKill of live #3).
- **Hypothesis**: the operator rolls out make-before-break (maxSurge 1,
  maxUnavailable 0): the new pod crash-loops, the two old pods keep
  serving, **no user impact**; the crash-loop alert of PR B fires within
  10 minutes; the operator diagnoses from `kubectl describe` and events and
  rolls back by re-applying the manifest from Git.
- **Pass**: availability 100 %; time to detect and time to recover written
  down; the rollback is the file in Git, not a hand edit.
- **Abort**: any old pod terminated before a new one is Ready (that would
  be a defect in the operator, recorded and stopped there).

### S3. The paging path: autoscaler down, then a node lost

- **Inject**: scale the Karpenter Deployment to 0 (Argo CD self-heal paused
  for that Application, as in live #3 step 4), then the Spot warning on
  one replica's node.
- **Hypothesis**: the replicas-available alert of PR B pages by email
  within 10 minutes of the scale-down (`KarpenterControllerDown` does not,
  see section 3); with no controller, the interrupted node is **not**
  replaced and the service runs on one replica (degraded, still within
  SLO); the operator follows `docs/runbooks/karpenter.md`, restores the
  controller through Argo CD, and the second replica is back within 5
  minutes of the restore.
- **Control run** (recorded either way): the same scale-down on release
  v2.3.3 rules alone would page nobody. If PR B is not merged, S3 is run
  to prove that gap, and its postmortem's first action item is PR B.
- **Pass**: page received and acknowledged; time to detect, to mitigate
  and to recover written down; availability at least 99.5 %.
- **Abort**: the remaining replica fails (total outage), or the session
  reaches its time cap.

## 5. Measures recorded for each scenario

Time to detect (injection to first alert or first human notice), time to
mitigate, time to recover (SLI back to steady state), requests failed,
SLI over the window, share of the 30-day budget consumed, alerts that fired
and did not, runbook steps that were wrong or missing.

## 6. Cost and safety

- Resources as live #4 plus a second model node: 2 system nodes On-Demand
  and 2 Spot `m7i-flex.large`. Expected window about 2 h 30 min.
- The cap is set in the BUDGET entry (A-019) after the real cost of live #4
  (A-018) is read from Cost Explorer; the planning figure is 1.5 to 2.5 USD
  before credits. If that exceeds the 2 EUR named in D-0158, the BUDGET
  entry says so and asks for a new approval.
- Forced destroy deadline, teardown and `scripts/verify-teardown.sh` exactly
  as `docs/runbooks/live.md`. No FIS (not available on the Free Plan).

## 7. After the game day

- One postmortem per scenario where a hypothesis failed or a human step
  was slow (blameless, `postmortem-template.md`), published in this
  repository.
- Every action item is a pull request or an issue with an owner; none stays
  only in the postmortem.
- The CV line "Not yet: on-call" changes only if the evidence supports it:
  "no paged on-call yet; incident response practised on EKS".
