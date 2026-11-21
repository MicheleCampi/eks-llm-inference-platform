# Game day #1 re-run evidence: 2026-11-21 (live #6)

The run was release v2.3.8 (operator v0.16.0), in eu-west-1, on cluster
`llm-inference`.
- **Plan and hypotheses, written before the session:** [rerun-v2.3.8.md](../gameday/rerun-v2.3.8.md).
- **Design:** [docs/gameday/README.md](../gameday/README.md). **Runbook:** [docs/runbooks/live.md](../runbooks/live.md).
- **Budget:** A-020, with a cap of 3,00 EUR and a maximum of 3 h. The forced destroy was set for 20:48Z.
- **Billable window:** 17:48:33Z (apply approved) to 20:09:00Z (destroy complete), about 2 h 21 min. Real cost is to be read from Cost Explorer, by record type.
- **Roles:** Michele was incident commander and operator. The AI agent was scribe and wrote the commands; Michele ran every one.

Account ids, public IPs and tokens are redacted. All times are UTC.

## Summary

| Test | Result |
|---|---|
| Apply through the pipeline on v2.3.8 | Run 44931878336, approved via `pending_deployments` at 17:48:33, complete 18:00:08 |
| System pool taint | 2 system nodes Ready with `CriticalAddonsOnly`; platform Applications Synced/Healthy |
| Grafana as code | Run 44936607410: Terraform **No changes** (objects kept from A-019) |
| Model with `zoneSpread: Required` | Ready at 18:40:32, about 1.5 min after `kubectl apply`. Replicas on Spot `general` nodes in **eu-west-1a and eu-west-1b** |
| Steady state | 5 min, 53 requests, all HTTP 200. p50 **3.81 s** (live #4 baseline: 3.83 s). Requests split 36/37 between the two pods |
| First request after Ready | **5.84 s** (game day #1: 17.18 s, live #4: 19.17 s). Under the 8 s threshold, but about 2 s above steady state: finding 1 |
| **S1', Spot interruption under load** | **Passed.** Availability and latency 100 % (97/97). Replacement in the zone that lost its replica; 2 replicas again in about 2 min |
| **S3', autoscaler down then a node lost** | **The fix is proven:** the replacement stayed **Pending with no node** for 10 min, never on a system node. Latency SLI met. **Availability SLI 99.320 %, below the 99.5 % objective**: 1 failed request of 147 (finding 2). Restore to 2 replicas in 2 min 53 s, in the missing zone |
| Alerts | `KarpenterControllerUnavailable` page, `ModelReplicasBelowSpec` ticket (first time live), `NodeNotReady`; all resolved by email after the restore. No false page (game day #1 finding 1 stays fixed) |
| Teardown | NodeClaims 0 at 19:52:55, NodeClasses deleted, verify-teardown failed as expected, destroy run 44943467437 (plan 0/0/67), **TEARDOWN CLEAN** at 20:09 (13 checks OK) |

## SLIs per scenario (probe log, `scripts/gameday-sli.py`)

| Scenario | Window | Requests | Failed | Availability | Latency ≤ 8 s | 30-day budget used |
|---|---|---|---|---|---|---|
| S1' | 18:50:43 to 18:59:58 | 97 | 0 | 100.000 % | 100.000 % | 0 % / 0 % |
| S3' | 19:34:26 to 19:49:05 | 147 | 1 | **99.320 %** | 99.320 % | 0.015 % / 0.002 % |

The only request that failed or took 8 s or more in the whole session:

| Time | Code | Seconds | What |
|---|---|---|---|
| 19:36:13 | 0 | 30.00 | client timeout: sent to the pod on the terminated instance, about 2 min after the termination (finding 2) |

With about 10 requests a minute, one failure in a 15-minute window is 0.68 %:
the window objective of 99.5 % allows no failure below 200 requests. The
30-day budget used is 0.015 %, the same as game day #1 S3.

## Hypotheses (written before the run) and results

| Scenario | Hypothesis | Result | Held? |
|---|---|---|---|
| S1' | 1. Before the injection the two replicas run in two zones | 1a (`41-126`) and 1b (`56-80`), both Spot `general` | yes |
| S1' | 2. Replacement in the zone that lost its replica, On-Demand while Spot is marked unavailable | New NodeClaim at 18:50:47 in **1b** (Karpenter log). Its capacity type was not captured (the log line is truncated); On-Demand is inferred from what followed: at 18:54:12 consolidation replaced it (`Underutilized ... replace ... savings: $0.05`) with a Spot node in 1b, after the 3-minute unavailable-offering TTL | zone: yes; On-Demand: inferred |
| S1' | 3. No request of 8 s or more | None of 8 s or more (latency SLI 100 %) | yes |
| S1' | 4. `ModelReplicasBelowSpec` stays silent | Available 1 for about 2 min (interruption), then again about 2 min (consolidation); no ticket | yes |
| S3' | 1. Page within 10 min of the scale-down | Email at 19:32, about 7 min after the scale to 0 | yes |
| S3' | 2. The replacement stays Pending, never on a system node | `qtj4d` Pending with **no node** from the eviction (19:36) to the restore (19:45:59); `kubectl get pods -o wide` before the restore: `Pending <none>` | **yes (game day #1 refuted this)** |
| S3' | 3. One replica within SLO, 2 requests lost at most | 1 lost; latency SLI met; availability SLI missed in this window (see above) | yes, with the SLI note |
| S3' | 4. `ModelReplicasBelowSpec` ticket 5 to 7 min after the pod is unavailable | Email at 19:44, about 8 min after the eviction | yes, 1 min late |
| S3' | 5. After the restore, a node in the missing zone and the replacement Ready and warm within 5 min | Karpenter 2/2 at 19:46:35; Spot node in **1a** at 19:47:09; pod Running 19:47:43; available 2 at 19:48:52 (2 min 53 s). No request of 8 s or more after it joined (the only failure is at 19:36:13) | yes |

## Findings

1. **The first request after Ready still costs about 2 s more than steady state** (5.84 s against 3.81 s).
   - The 1-token warmup of operator v0.16.0 removed most of the cold cost (17 to 19 s before).
   - The probe asks for 32 tokens with another prompt; the warmup asks for 1 token with "Hi". The rest of the cold path is not exercised.
   - Fix to evaluate in the operator: a warmup with the shape of real traffic (several tokens), measured in the CI first-request job. Within SLO today, so no page-worthy risk.
2. **A request was routed to a pod on a terminated instance about 2 minutes after the termination.**
   - The node was NotReady within 30 s of `terminate-instances`, but every request until 19:36:07 succeeded: the instance was still `shutting-down` and vLLM still answered.
   - The request at 19:36:13 reached it as it went down and timed out after 30 s. The pod was `Succeeded` at 19:36:32.
   - This is the plan's "requests sent to the dead endpoint"; the plan placed them before NotReady, and they came later.
   - Game day #1 lost one request in the same way (connection refused, 2 ms).
   - Standard mitigation: one retry on connect error or timeout at the client or gateway, with a shorter per-try timeout. Not implemented here: the probe calls the Service directly.
3. **Consolidation replaced the S1' replacement node 4 minutes later**, taking one replica away for about 2 min (18:54:47 to 18:56:32). That is the expected trade between cost and availability, protected by the PDB, with no failed request. It explains game day #1 open question 7 as the same mechanism, not yet proven for that session.

## Not proven here

- AWS itself reclaiming a Spot instance (S1' used the SQS message; FIS is not on the Free Plan).
- S2 (no fix touched it; it passed in game day #1).
- GPU serving. This model is a functional CPU service on 2 vCPU nodes.

## Timeline

    17:48:33 apply.yml on v2.3.8 approved (run 44931878336); 18:00:08 apply complete
    -        2 system nodes Ready, taint CriticalAddonsOnly; 12 Applications, alloy/monitoring Degraded until the secret
    -        remote-write secret put (hidden prompt); ExternalSecret SecretSynced
    18:38    observability.yml dispatched (run 44936607410, No changes); tests/gameday/model.yaml applied
    18:40:32 VllmService Ready; replicas 1a Spot (41-126) and 1b Spot (56-80)
    18:42:44 probe: first request 5.84 s, then about 3.8 s
    18:42:44-18:47:58 steady state, 53 requests HTTP 200
    18:50:40 S1' inject: Spot interruption warning for i-...efc9 (1b, 56-80)
    18:50:43 Karpenter: CordonAndDrain from the interruption message
    18:50:47 replacement NodeClaim launched in 1b
    18:52:44 available 2 (replica on 59-40, 1b)
    18:53:11 old node deleted
    18:54:12 consolidation: Underutilized replace 59-40, savings $0.05
    18:56:32 available 2 again (replica on 59-60, 1b Spot); 18:57:12 59-40 deleted
    ~19:25  S3': self-heal of root and karpenter off; Karpenter scaled to 0
    19:32    KarpenterControllerUnavailable page (email)
    19:34:22 S3' inject: terminate-instances on 41-126 (1a)
    19:34:52 node NotReady; available still 2
    19:36:13 the failed request (timeout 30 s)
    19:36:32 pod on 41-126 Succeeded; replacement qtj4d Pending, no node
    19:44    ModelReplicasBelowSpec ticket (email)
    19:45:59 restore: kubectl apply -f gitops/root-app.yaml
    19:46:35 Karpenter 2/2
    19:47    NodeNotReady (email; rule for: 10m)
    19:47:09 new Spot node in 1a (43-117); 19:47:43 qtj4d Running
    19:48:52 available 2
    19:52    page and ticket resolved (email)
    19:52:55 NodeClaims 0 (namespace deleted, sync off, NodePools deleted)
    19:57:15 destroy approved (run 44943467437, plan 0/0/67)
    20:09:00 destroy success; TEARDOWN CLEAN
