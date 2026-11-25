# S3'' on v2.4.3: no request lost when a node shuts down

Written 2026-11-25, before the session. Runs in the first live session of
v2.4.x, under its BUDGET entry (platform-notes); results go to
`docs/evidence/` after it. Same service, SLO, probe and roles as
[README.md](README.md); this page lists only what changes and the hypotheses
to prove or refute.

## Why

In the re-run of 2026-11-21 (A-020, [evidence](../evidence/gameday-rerun-2026-11-21.md),
finding 2), S3' lost one request: the one sent at 19:36:13, about 111 s
after `terminate-instances`, to the replica on the terminated instance. The
availability SLI of the window was 99.32 %, below 99.5 %.

Cause (operator ADR-0028): EKS AL2023 1.34+ runs the kubelet with graceful
node shutdown (150 s). On an instance shutdown the kubelet drains its pods
without the API (no deletionTimestamp) and stops probing their readiness
as soon as the termination starts (kubernetes/kubernetes#105780). The pod
stayed Ready and routed through the whole 110 s pre-stop sleep, and SIGTERM
reached a server still in the Service.

## What changed

| Fix | Release |
|---|---|
| The operator watches Nodes and deletes, through the API, the pods it manages on a node whose kubelet reports "node is shutting down": they leave the Service at once, the pre-stop sleep drains them | v2.4.3, operator v0.18.0 (ADR-0028) |
| The game day probe retries once, only when the first try never connected, and the SLI prints the first-try availability next to the user's | eks #91 (in v2.4.2) |

Proved for free before the session: the operator's CI job `node-shutdown`
on kind (graceful node shutdown with the EKS values, a client without
retry) lost 0 of 604 and 0 of 601 requests, and the target pod answered
nothing after the signal; with the operator stopped it stayed routed until
+109 s (run 45291129700, two attempts).

## Scenario

As S3' ([rerun-v2.3.8.md](rerun-v2.3.8.md)): Karpenter to 0 with self-heal
off, then `aws ec2 terminate-instances` on one model replica's node after
the page. The operator runs on pool system, so it is not on the node that
shuts down.

- **Hypotheses**:
  1. Within 10 s of `terminate-instances` the node's Ready condition says
     "node is shutting down" (`kubectl get node NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'`).
     If EC2 cuts the instance before the kubelet sees the shutdown, there is
     no graceful path and this hypothesis is refuted: write it down, it
     decides whether the fix applies on EKS at all.
  2. Within seconds of that, the operator logs "deleted pod ... so it leaves
     the Service", the pod has a deletionTimestamp, and its endpoint is
     `ready: false`
     (`kubectl -n inference-test get endpointslices -o yaml`).
  3. No probe line with `first` other than 200 points at the terminated
     replica after the shutdown is reported: first-try availability and
     user availability are both at least 99.5 % over the S3'' window.
  4. The replacement is created at once and stays **Pending** (Karpenter at
     0, pool system tainted), never on a system node, as in S3'.
  5. `ModelReplicasBelowSpec` opens a ticket 5 to 7 minutes after the pod is
     no longer available; after the restore, a node in the missing zone and
     the replacement Ready and warm within 5 minutes, as in S3'.
- **Pass**: hypotheses 2 and 3; availability and latency SLIs met.
- **Abort**: as S3'.

Before teardown: `kubectl delete namespace inference-test`, then `live.md`
step 9.
