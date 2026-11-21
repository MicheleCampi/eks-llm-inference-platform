# Postmortem: a model replica survived a lost node on capacity meant for the platform

Blameless: this document is about systems and decisions, not people. Format:
[postmortem-template.md](postmortem-template.md).

| | |
|---|---|
| Date (UTC) | 2026-11-20 |
| Scenario / incident | game day #1 S3: autoscaler down, then a node lost |
| Release | eks v2.3.5, operator v0.13.0 |
| Incident commander | Michele (operator) |
| Scribe | AI agent (changed nothing) |
| Status | action items 1 to 4 in code; 5 (live re-run) open |

## Summary

With Karpenter scaled to 0, one of the two model nodes was terminated. Users
lost 1 request, and the service stayed within its SLO. The service did not
degrade as designed. Instead, the lost replica restarted in about 3 minutes on
an On-Demand node of the **system** node group, which is meant only for
platform controllers. The SLO held for a reason the design did not intend.

## Impact

- **Requests failed:** 1 of 236, at 21:52:25 (connection refused in 2 ms).
- **Availability SLI:** 99.576 % over 21:41:05 to 22:03:56 (objective 99.5 %).
- **Latency SLI:** 98.729 % within 8 s (objective 95 %). Two requests took 19 s, including the first request to the replica that replaced the lost one.
- **30-day error budget consumed:** availability 0.015 %, latency 0.005 %.
- **Cost:** within the session total of BUDGET A-019, to be read from Cost Explorer.

## Timeline (UTC)

| Time | Event | Source |
|---|---|---|
| ~21:42 | Self-heal of `root` and `karpenter` off; Karpenter scaled to 0 | command |
| 21:49 | `KarpenterControllerUnavailable` pages by email; `KarpenterControllerDown` silent | alert |
| 21:50:33 | Injection: `ec2 terminate-instances` on node `53-229` (replica `schhx`) | command |
| 21:50:34 | Node NotReady | `kubectl get nodes` |
| 21:52:25 | 1 probe request refused | probe |
| 21:52:36 | `schhx` Completed; replacement `7vzgs` created | `kubectl get pods` |
| 21:53:46 | `7vzgs` Ready on `ip-10-42-46-193`, a system node | `kubectl get pods -o wide` |
| 22:00:51 | Restore: `kubectl apply -f gitops/root-app.yaml` | command |
| 22:03:01 | Karpenter 2/2 | `kubectl get deploy` |
| 22:04 | `KarpenterControllerUnavailable` resolved | alert |

Time to detect the controller outage: about 7 min (page). The node loss
itself raised no alert; see action item 4. Time to mitigate: none needed, the
service stayed in SLO. Time to recover the autoscaler: about 2 min after the
restore.

## What happened and why

1. The node group of pool `system` carries a label (`platform.michelecampi.dev/pool=system`) and **no taint** (`modules/eks/main.tf`). A label attracts only the pods that ask for it. It keeps nothing away.
2. The model's pods have no node selector or affinity for pool `general`. The operator v0.13.0 sets none, and no policy adds one. A model pod can therefore schedule on any node with room.
3. The terminated instance stopped its kubelet at once. The node went NotReady in 1 s, and the pod ended in about 2 min, before the 300 s taint eviction.
4. The ReplicaSet created a replacement. With Karpenter at 0 no node could be added, but a system node (`m7i-flex.large`, On-Demand) had 6 GiB free, and the scheduler used it.
5. In the design (`docs/gameday/README.md`, S3) the replacement stays Pending and the service runs degraded on one replica. That hypothesis assumed the model could only run on `general`, and nothing enforced that.

## Hypothesis vs result

| Hypothesis written before | Result | Held? |
|---|---|---|
| Page within 10 min; `KarpenterControllerDown` silent | 7 min; silent | yes |
| Node NotReady within about 50 s | 1 s | faster |
| At most 2 requests lost | 1 | yes |
| Pod evicted after 300 s by the taint, replacement Pending, 1 replica serving | Pod closed in about 2 min; replacement Ready on a system node; 2 replicas serving | **no** |
| Second replica back within 5 min of the restore | Not applicable (never lost) | n/a |

## What went well

- The new page `KarpenterControllerUnavailable` fired on the case it was written for, and the old `KarpenterControllerDown` stayed silent, as the design predicted.
- The injection was a real instance termination, chosen by reading the Karpenter controller before the session (eks #70). The original SQS-warning injection would have lost no node.
- The restore went through Git (`root-app.yaml`), not a hand scale.

## What went wrong

- Isolation between platform capacity and workload capacity exists only as a convention.
- The loss of a model node raised no alert. Only the autoscaler outage paged.

## Where we were lucky

- The system node had 6 GiB free. With less room, the replacement would have stayed Pending, as designed.
- With more room, a heavier workload landing there could starve Argo CD, Karpenter or ESO, the controllers that recover everything else.

## Action items

| Item | Type | Owner | Tracking |
|---|---|---|---|
| 1. Taint the system node group (`CriticalAddonsOnly=true:NoSchedule`, the EKS convention for a dedicated add-on node group) and add the toleration to every platform chart. CI checks every platform workload tolerates the taint and no team or test workload does | prevent | Michele | eks v2.3.6 with operator v0.14.0 (scheduling values) |
| 2. Pin model pods to Karpenter pools: a node selector in the operator (`platform.michelecampi.dev/pool` or `karpenter.sh/nodepool`), or a Kyverno mutate rule for `inference-*` and `team-*` namespaces. Decide in the PR; the Kyverno rule also covers non-operator workloads | prevent | Michele | covered by item 1 in eks v2.3.6: with pool system tainted and `restrict-system-pool` denying the toleration, the only node a model pod can use without asking is pool general (pool gpu carries the `nvidia.com/gpu` taint) |
| 3. Topology spread across zones for model replicas, because after S1 both replicas sat in eu-west-1b | prevent | Michele | operator v0.15.0 `spec.zoneSpread`; `Required` on the game day model in eks v2.3.7 |
| 4. A ticket alert when a model's ready replicas drop below spec for 5 minutes (`kube_deployment_status_replicas_available < kube_deployment_spec_replicas`), scoped to inference namespaces | detect | Michele | eks #72, merged |
| 5. Re-run S3 after items 1 and 2: the replacement must stay Pending and the service must run degraded within SLO | process | Michele | next game day |

## Evidence

[gameday-2026-11-20.md](../evidence/gameday-2026-11-20.md): the timeline, the SLI tables, the probe outliers and the audit trail.
