# Game day #1: incident response on the EKS inference platform

Status: **run on 2026-11-20 (live #5, v2.3.5)**: all 3 scenarios within SLO, one hypothesis refuted in S3. Evidence: [gameday-2026-11-20.md](../evidence/gameday-2026-11-20.md); postmortem: [postmortem-2026-11-20-s3.md](postmortem-2026-11-20-s3.md). Designed with the nodes off (D-0158, 2026-11-18).
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

Service: `qwen-0-5b-cpu` (VllmService, `tests/gameday/model.yaml`),
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

Prerequisites, each with a CI check in `ci/validate-gitops.sh` (done offline,
2026-11-18):

1. `tests/gameday/probe.yaml` and `scripts/gameday-sli.py`, tested on
   `ci/fixtures/gameday/probe.log` by `ci/test-gameday-sli.py`.
2. `tests/gameday/model.yaml`: the service at 2 replicas with a
   PodDisruptionBudget `minAvailable: 1` placed before it. Required: the
   operator v0.13.0 creates no PDB, so the Kyverno policy `require-pdb`
   **denies** its Deployment at 2 replicas. CI admits the operator's
   2-replica Deployment (`ci/fixtures/kyverno/vllm-2-replicas.yaml`) with the
   PDB and rejects it without. Found while designing, not live. The file is
   also the rollback target of S2. `tests/live/inference-cpu.yaml` stays at
   1 replica and no PDB: there a `minAvailable: 1` PDB would block every
   drain until terminationGracePeriod (1 h).
3. Two alerts with promtool tests, their metrics added to kube-state-metrics
   and to the Alloy allow-list: `PodCrashLooping` (ticket,
   `docs/runbooks/workloads.md`) and `KarpenterControllerUnavailable` (page,
   `docs/runbooks/karpenter.md`). The second closes a gap found while
   designing S3: `KarpenterControllerDown` is `up == 0` on targets discovered
   from the Service endpoints, so a controller **scaled to 0** leaves no
   target, no `up` series and no page (a crashing pod stays a target and
   does page). `absent()` stays out, as the rules file explains: after a
   destroy it would page forever.
4. The Grafana remote-write secret step of `live.md` is in scope this time:
   detection is part of the test. The rules reach Grafana through
   `observability.yml` after the apply, as in live #3.

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
- **Prediction from the code** (`markUnavailableOfferings`, v1.15.1): a
  Spot interruption marks that instance type, zone and capacity type
  unavailable for 3 minutes (`UnavailableOfferingsTTL`). Only
  `m7i-flex.large` of pool `general` fits a 6 GiB model pod, so the
  replacement is `m7i-flex.large` Spot in **another zone**, or On-Demand.
  Recorded: zone and capacity type of the old and the new node.
- **Pass**: availability over the window at least 99.5 %; latency SLI met
  (one replica holds the probe's rate).
- **Abort**: both replicas not Ready for more than 2 minutes.

### S2. A bad change: the live #3 defect, re-introduced on purpose

- **Inject**: `kubectl patch` the VllmService to remove
  `VLLM_CPU_KVCACHE_SPACE` (KV cache back to 4 GiB: the OOMKill of live #3).
- **Hypothesis**: the operator rolls out make-before-break (maxSurge 1,
  maxUnavailable 0): the new pod crash-loops, the two old pods keep
  serving, **no user impact**; `PodCrashLooping` fires within
  10 minutes; the operator diagnoses from `kubectl describe` and events and
  rolls back by re-applying `tests/gameday/model.yaml` from Git.
- **Pass**: availability 100 %; time to detect and time to recover written
  down; the rollback is the file in Git, not a hand edit.
- **Abort**: any old pod terminated before a new one is Ready (that would
  be a defect in the operator, recorded and stopped there).

### S3. The paging path: autoscaler down, then a node lost

- **Inject**: scale the Karpenter Deployment to 0 (Argo CD self-heal paused
  for that Application, as in live #3 step 4); after the page, **terminate
  the EC2 instance** of one replica's node (`aws ec2 terminate-instances`).
- **Why not the Spot warning of S1** (found 2026-11-19 reading the
  controller, `aws/karpenter-provider-aws` v1.15.1,
  `pkg/controllers/interruption/`): `tests/live/spot-interruption.sh` only
  puts a message on the SQS queue; nothing in AWS reclaims the instance. The
  interruption controller is the only reader of that queue, so with
  Karpenter at 0 the message waits, no node is lost and the scenario tests
  nothing. The queue keeps a message 300 s (`message_retention_seconds`,
  `modules/eks/karpenter.tf`), less than the page takes (`for: 5m` plus
  evaluation and email): restored later, the warning has expired and
  nothing ever happens; restored sooner, the drain runs with the controller
  back. Either way, never the degraded window this scenario is about. A
  real termination is what a lost Spot node is.
- **Hypothesis**: `KarpenterControllerUnavailable` pages by email
  within 10 minutes of the scale-down (`KarpenterControllerDown` does not,
  see section 3). After the termination nothing replaces the node: the Node
  goes NotReady within about 50 s (node monitor grace period), its pod
  leaves the Service endpoints, and the probe loses at most the requests
  sent to the dead endpoint before that (each waits up to its 30 s
  timeout: 2 or fewer). The pod is evicted by the `unreachable` taint after
  300 s, without the PDB (a taint eviction is not an Eviction API call),
  and its replacement stays Pending: the service runs on one replica
  (degraded, still within SLO). The operator follows
  `docs/runbooks/karpenter.md` and restores the controller through Argo
  CD; Karpenter launches a node for the Pending pod at once (the second
  replica is back within 5 minutes of the restore), and its NodeClaim
  garbage collection (every 2 minutes) deletes the NodeClaim and Node of
  the terminated instance.
- **Control**: `KarpenterControllerDown` must stay silent (no target);
  recorded as the proof of the gap that `KarpenterControllerUnavailable`
  closes.
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

## 8. Run sheet

After `docs/runbooks/live.md` steps 0 to 8 (apply, GitOps, Grafana secret
and `observability.yml`), before its step 9 (destroy). One command at a time;
the scribe writes the UTC time of each line into the timeline.

Setup and steady state:

    kubectl apply -f tests/gameday/model.yaml
    kubectl -n inference-test get vllmservice qwen-0-5b-cpu -w        # until Ready
    kubectl -n inference-test get pods -o wide                        # 2 pods, 2 different nodes
    kubectl apply -f tests/gameday/probe.yaml
    kubectl -n inference-test logs deploy/probe -f                    # 5 min of code 200 = steady state

After each scenario, save the log and compute the SLIs (window from the
injection to steady state again):

    kubectl -n inference-test logs deploy/probe --tail=-1 > probe-S1.log
    python3 scripts/gameday-sli.py probe-S1.log --from <UTC> --to <UTC>

S1, Spot interruption:

    bash tests/live/spot-interruption.sh       # first running Spot node of pool general: here, one model replica's node
    kubectl -n inference-test get pods -o wide -w
    kubectl -n inference-test get pdb qwen-0-5b-cpu -w                # allowed disruptions never below 0

S2, bad change, then rollback from Git:

    kubectl -n inference-test patch vllmservice qwen-0-5b-cpu --type json -p '[{"op":"remove","path":"/spec/env"}]'
    kubectl -n inference-test get pods -w                             # new pod restarts, old pods stay Ready
    # wait for PodCrashLooping in the email; diagnose with docs/runbooks/workloads.md
    kubectl apply -f tests/gameday/model.yaml

S3, autoscaler down, then a node lost (self-heal of `root` and `karpenter`
off first, as in `live-3.md` step 4):

    kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}'
    kubectl -n argocd patch application karpenter --type merge -p '{"spec":{"syncPolicy":null}}'
    kubectl -n kube-system scale deploy/karpenter --replicas=0
    # wait for KarpenterControllerUnavailable in the email; then terminate one replica's instance:
    N=$(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu -o jsonpath='{.items[0].spec.nodeName}'); I=$(kubectl get node "$N" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}'); echo "$N $I"; aws --region eu-west-1 ec2 terminate-instances --instance-ids "$I" --query 'TerminatingInstances[0].CurrentState.Name' --output text
    kubectl get nodes -w                                              # NotReady within ~50 s; no new node while Karpenter is at 0
    # recover with docs/runbooks/karpenter.md, then restore Git's sync policies:
    kubectl apply -f gitops/root-app.yaml

Before teardown: `kubectl delete namespace inference-test`, then
`live.md` step 9.
