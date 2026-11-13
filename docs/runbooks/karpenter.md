# Runbook: Karpenter

Alerts from `observability/karpenter-rules.yaml`. Metrics reach Grafana Cloud
through Alloy (`gitops/apps/alloy.yaml`, job `karpenter`).

## KarpenterNodePoolCpuLimitReached (severity page)

The NodePool provisioned all the CPU in `spec.limits.cpu` for 5 minutes: new
pods that need a node stay Pending.

1. `kubectl get nodepool default -o jsonpath='{.status.resources.cpu}'` against
   `spec.limits.cpu` (8 in `gitops/karpenter/nodepool.yaml`).
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

## KarpenterSpotInterruption (severity ticket)

EC2 sent a Spot interruption or rebalance message to the SQS queue in the last
10 minutes. Karpenter cordons, drains and replaces the node on its own.

1. `kubectl get nodeclaims -o wide` and `kubectl get events -A | grep -i interrupt`
2. If interruptions repeat, widen the instance types or zones of the NodePool.
