# Runbook: workloads

Alerts of group `workloads` in `observability/karpenter-rules.yaml`, from
kube-state-metrics through Alloy. Severity ticket goes to platform-email.

## PodCrashLooping (severity ticket)

A container outside `kube-system` restarted 3 or more times in 10 minutes.
On a VllmService this is usually a bad change: the operator rolls out
make-before-break (maxSurge 1, maxUnavailable 0), so the old replicas keep
serving and users see nothing, but the change never completes. A ticket, not
a page, for that reason; if users are affected the SLO alerts page.

1. `kubectl -n <namespace> get pods -o wide`: which pod, how many restarts,
   are the old replicas still Ready.
2. `kubectl -n <namespace> describe pod <pod>`: `Last State` reason and exit
   code. `OOMKilled` / 137 = memory (for vLLM CPU: the KV cache,
   `VLLM_CPU_KVCACHE_SPACE`, live #3); `Error` = read the logs.
3. `kubectl -n <namespace> logs <pod> --previous --tail=-1`: the last lines
   before the crash.
4. What changed: `git log` of the manifest, and for a VllmService
   `kubectl -n <namespace> get vllmservice <name> -o yaml` against Git.
5. Who changed it and when: the EKS audit log (CloudWatch Logs
   `/aws/eks/<cluster>/cluster`, streams `kube-apiserver-audit*`), filtered on
   verb `patch` or `update` and the object (game day #1 reconstructed S2 this
   way, `docs/evidence/gameday-2026-11-20.md`).

Diagnose before acting: game day #1 rolled back on the watch output alone.
The rollback was right, but steps 1 to 3 take a minute and name the cause
the postmortem needs.

Act: roll back to what Git declares (`kubectl apply -f` the file from Git,
or revert the commit and let Argo CD sync), never a hand edit that Git does
not hold. Confirm the crashing pod is gone and the Deployment has its desired
replicas available. Write the cause down (postmortem template in
`docs/gameday/postmortem-template.md` if users were affected or the
detection was slow).

## ModelReplicasBelowSpec (severity ticket)

A Deployment in an `inference-*` or `team-*` namespace has had fewer
available replicas than its spec for 5 minutes. The service still runs on
the others, so this is a ticket: capacity is missing, not yet users.

1. `kubectl -n <namespace> get pods -o wide`: which replica is missing, and
   whether it is Pending, crashing, or on a node that is NotReady.
2. Pending: `kubectl -n <namespace> describe pod <pod>` events. "no nodes
   available" with Karpenter down means `KarpenterControllerUnavailable` has
   paged too: follow `docs/runbooks/karpenter.md`. A NodePool at its limit
   means `KarpenterNodePoolCpuLimitReached`.
3. A crashing replica: see PodCrashLooping above.

Act on the cause (controller, capacity, bad change), never by moving the
model to the system node group: that capacity belongs to the platform's
controllers (game day #1 S3 postmortem).
