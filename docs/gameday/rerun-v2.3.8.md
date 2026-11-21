# Game day #1, re-run on v2.3.8: the fixes under the same failures

Written 2026-11-21, before the session. BUDGET A-020 (platform-notes).
Results: [evidence/gameday-rerun-2026-11-21.md](../evidence/gameday-rerun-2026-11-21.md).
Same service, SLO, probe and roles as [README.md](README.md); this page
lists only what changes and the hypotheses to prove or refute.

## What changed since game day #1 (v2.3.5)

| Fix | Release | Postmortem item |
|---|---|---|
| Pool system tainted `CriticalAddonsOnly`; platform tolerates it, `restrict-system-pool` denies the toleration to everyone else | v2.3.6 | 1, 2 |
| Alert `ModelReplicasBelowSpec` (ticket, available < spec for 5 min, `inference-*` and `team-*`) | v2.3.6 (#72) | 4 |
| `zoneSpread: Required` on the game day model: at most one replica more in one zone than in another, DoNotSchedule | v2.3.7, operator v0.15.0 | 3 |
| Ready means warm: a startup probe sends one 1-token completion before Ready | v2.3.8, operator v0.16.0 | 6 |
| Argo CD 3.5.8 | v2.3.7 | none |

## Scenarios

Only S1 and S3: S2 (bad change, rollback from Git) passed and no fix
touched it.

### S1'. Spot interruption under load

- **Inject**: as S1 (`tests/live/spot-interruption.sh` on a model replica's
  Spot node).
- **Hypotheses**:
  1. Before the injection the two replicas run in two different zones.
  2. The replacement goes to the zone that lost its replica. In the other
     zone, the surviving replica already makes that zone count one more,
     so DoNotSchedule rejects it. Karpenter has marked Spot `m7i-flex.large`
     in that zone unavailable for 3 minutes
     (`UnavailableOfferingsTTL`, the S1 prediction of game day #1), so the
     replacement is **On-Demand** in that zone (pool general allows both),
     unless the claim comes after the 3 minutes.
  3. No probe request takes 8 s or more except those in flight on the
     drained pod: the first request routed to the replacement is warm
     (game day #1: 17.18 s).
  4. `ModelReplicasBelowSpec` stays silent: available is back to spec in
     under 5 minutes (game day #1: about 2 minutes).
- **Pass**: availability at least 99.5 %; latency SLI met; hypotheses 1 and
  2 seen on `kubectl get pods,nodes -L topology.kubernetes.io/zone,karpenter.sh/capacity-type`.
- **Abort**: both replicas not Ready for more than 2 minutes.

### S3'. Autoscaler down, then a node lost (postmortem item 5)

- **Inject**: as S3 (Karpenter to 0 with self-heal off, then
  `aws ec2 terminate-instances` on one replica's node after the page).
- **Hypotheses**:
  1. `KarpenterControllerUnavailable` pages by email within 10 minutes of
     the scale-down (game day #1: about 7 minutes).
  2. After the eviction (300 s after NotReady), the replacement stays
     **Pending**. It must not run on pool system (tainted; game day #1 used
     a system node). It cannot fit next to the surviving replica: that
     node has no room for 6 GiB, and the zone spread forbids it.
     `kubectl get pods -o wide` shows it Pending, never on a system node.
  3. The service runs on one replica within SLO: at most the requests sent
     to the dead endpoint before NotReady fail (2 or fewer).
  4. `ModelReplicasBelowSpec` opens a ticket (email) about 5 to 7 minutes
     after the pod is no longer available.
  5. After the restore (`docs/runbooks/karpenter.md`), Karpenter launches
     one node in the zone that lacks a replica, and the replacement is
     Ready within 5 minutes of the restore, warm (no request of 8 s or
     more after it joins).
- **Pass**: hypotheses 2 and 3 hold (this is what failed in game day #1:
  the replacement took a system node); page and ticket received; times
  written down.
- **Abort**: the remaining replica fails, or the session reaches its time
  cap.

## Run sheet

Steps 0 to 8 of `docs/runbooks/live.md` with `--ref v2.3.8`, then the
setup and steady state of [README.md](README.md) section 8, then S1' and
S3' as there (S2 skipped). Two additions:

- **Zones and capacity, at setup and after each scenario**:
  `kubectl -n inference-test get pods -o wide` and
  `kubectl get nodes -L topology.kubernetes.io/zone,karpenter.sh/capacity-type,platform.michelecampi.dev/pool`.
- **Every wait prints one line per iteration** (the SSH session drops when
  idle; game day #1 lost 28 minutes to a silent loop).

Before teardown: `kubectl delete namespace inference-test`, then
`live.md` step 9. Real cost and evidence go into A-020 and
`docs/evidence/` after the session.
