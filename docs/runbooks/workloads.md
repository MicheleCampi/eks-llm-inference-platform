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

Act: roll back to what Git declares (`kubectl apply -f` the file from Git,
or revert the commit and let Argo CD sync), never a hand edit that Git does
not hold. Confirm the crashing pod is gone and the Deployment has its desired
replicas available. Write the cause down (postmortem template in
`docs/gameday/postmortem-template.md` if users were affected or the
detection was slow).
