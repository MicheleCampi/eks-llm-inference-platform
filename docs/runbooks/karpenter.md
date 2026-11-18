# Runbook: Karpenter and nodes

Alerts from `observability/karpenter-rules.yaml`. Metrics reach Grafana Cloud
through Alloy (`gitops/apps/alloy.yaml`: job `karpenter`, and job
`kube-state-metrics` for NodeNotReady). Severity page goes to
platform-oncall-email, ticket to platform-email.

## KarpenterNodePoolCpuLimitReached (severity page)

The NodePool provisioned all the CPU in `spec.limits.cpu` for 5 minutes: new
pods that need a node stay Pending.

1. `kubectl get nodepool general -o jsonpath='{.status.resources.cpu}'` against
   `spec.limits.cpu` (8 in `gitops/karpenter/nodepool-general.yaml`). Pool
   `gpu` has limits 0 by design (gated): it never fires this alert.
2. `kubectl get pods -A --field-selector=status.phase=Pending`: which workload
   asks for capacity.
3. `kubectl get nodeclaims`: nodes stuck launching also count against the limit.

Act: the limit is a cost cap, not a bug. Raise it in Git only with a new
BUDGET entry; otherwise scale the workload down and say so.

## KarpenterControllerDown (severity page)

`up{job="karpenter"} == 0` for 5 minutes: Alloy reaches the Service, the
controller does not answer. Nothing scales out or in, interruptions are not
handled.

1. `kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter`
2. `kubectl -n kube-system logs deploy/karpenter --tail=100`: Pod Identity or
   IAM errors (role `llm-inference-karpenter`, `modules/eks/karpenter.tf`).

Limit: if Alloy itself stops, `up` disappears and this alert does not fire.
No `absent()` by choice, because it would page forever after a destroy.
A controller scaled to 0 or never scheduled has no endpoint, so no target
and no `up`: KarpenterControllerUnavailable covers that case.

## KarpenterControllerUnavailable (severity page)

`kube_deployment_status_replicas_available` for `kube-system/karpenter` below
1 for 5 minutes: no replica runs at all (scaled to 0, Pending, or every pod
crashing). Same effect as KarpenterControllerDown: no scale-out, no
interruption handling. Added after designing game day #1 (scenario S3).

1. `kubectl -n kube-system get deploy karpenter`: desired vs available. A
   desired count of 0 means someone or something scaled it down: check
   `kubectl -n argocd get application karpenter -o jsonpath='{.spec.syncPolicy}'`
   (self-heal paused?) and the Argo CD history.
2. `kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide`
   and `kubectl -n kube-system describe pod <pod>`: Pending on the system
   node group (capacity), or CrashLoopBackOff (then the steps of
   KarpenterControllerDown).

Act: restore from Git, not by hand: re-enable self-heal on the `karpenter`
Application or `argocd app sync karpenter`; the replica count comes from the
chart values in `gitops/apps/karpenter.yaml`. Confirm with
`kubectl -n kube-system rollout status deploy/karpenter`, then that pending
pods get NodeClaims (`kubectl get nodeclaims -w`).

## KarpenterSpotInterruption (severity ticket)

EC2 sent a Spot interruption or rebalance message to the SQS queue in the last
10 minutes. Karpenter cordons, drains and replaces the node on its own.

1. `kubectl get nodeclaims -o wide` and `kubectl get events -A | grep -i interrupt`
2. If interruptions repeat, widen the instance types or zones of the NodePool.

## KarpenterNodeClaimLaunchFailed (severity ticket)

Karpenter deleted a NodeClaim in the last 30 minutes for `launch_timeout`
(no instance after 5 min), `registration_timeout` (instance up, node not
registered after 15 min) or `nodeclass_not_ready`. The label `reason` says
which.

1. `kubectl get nodeclaims` and `kubectl describe nodeclaim <name>`: the
   `Launched` and `Registered` conditions carry AWS's message.
2. `nodeclass_not_ready`: `kubectl get ec2nodeclass -o wide`; the status
   conditions name the subnet, security group, AMI or instance profile that
   did not resolve.
3. `registration_timeout`: the node could not join. Check the node role's
   access entry (`modules/eks`), the pinned AMI alias, and egress (NAT) from
   the private subnet. Console output: `aws ec2 get-console-output
   --instance-id <id> --latest`.

Act: fix in Git; Karpenter retries on its own.

## KarpenterInsufficientCapacityRepeated (severity ticket)

EC2 refused 3 or more launches for lack of capacity in 30 minutes, for one
pool and capacity type. Spot pods still get On-Demand as fallback, at a
higher price.

1. `kubectl get events -A --field-selector reason=InsufficientCapacityError`
2. Widen the pool: more instance types or zones. On this Free Plan account the
   list cannot grow (README Findings #1); say so in the incident note.

## KarpenterPodsUnschedulable (severity page)

At least one pod has had no NodePool able to host it for 15 minutes, so work
is not running.

1. `kubectl get pods -A --field-selector=status.phase=Pending`
2. `kubectl describe pod <name>`: Karpenter's event says why (limit reached,
   no pool matches the requirements or tolerations, an unsupported resource).
3. If `KarpenterNodePoolCpuLimitReached` fires too, follow that section. A pod
   asking `nvidia.com/gpu` stays Pending by design while pool `gpu` is gated
   (limits 0, `gitops/karpenter/nodepool-gpu.yaml`).

## NodeNotReady (severity page)

A node has reported Ready other than `true` for 10 minutes. A node that
Karpenter terminates loses its series and does not fire this.

1. `kubectl get nodes -L platform.michelecampi.dev/pool,karpenter.sh/capacity-type`
2. `kubectl describe node <name>`: conditions and last heartbeat.
3. Pool `general`: Karpenter's node repair is alpha and off (chart
   `featureGates.nodeRepair`); delete the
   NodeClaim (`kubectl delete nodeclaim <name>`) and Karpenter replaces the
   node within the disruption budgets. Pool `system`: the managed node group
   replaces an unhealthy instance; check the ASG activity in the console.
