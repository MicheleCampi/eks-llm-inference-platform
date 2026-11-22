# Live session A-022: v2.4.1, vLLM v0.11.2 against v0.34.0 on one m7i-flex node

**Done 2026-11-22**: [evidence](../evidence/live-a022-2026-11-22.md). v2.4.1
fixes A-021 finding 1; on one Xeon 8488C node v0.34.0 is 1.45 x v0.11.2 at
steady state. `tests/ab/model-v0.11.2.yaml` was removed after the session
(image not deployable outside the A/B); it is in Git history at ca37c1e.

One bounded session on release **v2.4.1** (Kyverno reports RBAC fix #81, AMI
1.36.5-20261119, operator v0.17.0). Two goals, nothing else:

1. **v2.4.1 comes up from Git and fixes A-021 finding 1**: every Argo CD
   application Synced and Healthy, `policies` included, ValidatingPolicy
   `karpenter-config-from-git` ready; nodes on AMI 1.36.5-20261119.
2. **A/B of the vLLM CPU release on the same machine** (A-021 finding 3):
   steady p50 5.86 s on v0.34.0 (A-021) against 3.81 s on v0.11.2 (A-020),
   both on m7i-flex.large but on different nodes and days; the CI study
   (operator runs 45018253568, 45020445163) found at most ~10 % between the
   releases on the same CPU. Here one replica runs **v0.11.2, then v0.34.0,
   then v0.11.2 again on the same node**, with the same probe, and the node's
   CPU is recorded.

How the result is read, written before the session:

- B/A ≥ 1.3 with A1 and A2 within 10 % of each other: the regression is real
  on this CPU. Next: an upstream issue with the data (vLLM CPU backend), and
  v0.34.0 stays with the number stated as measured.
- B/A ≤ 1.1: on the same node the releases are equal; the A-021 gap came from
  the node or the day (noisy neighbour, m7i-flex performance model). Claims say
  so; no upstream issue.
- A1 and A2 more than 10 % apart: the node itself drifted; the A/B is not
  conclusive, recorded as such.

No chaos scenarios. Budget: BUDGET A-022, ceiling 2,00 EUR, at most 2 h from
apply. Steps that are not specific to this session are in [live.md](live.md)
and referenced by number. Every number in the evidence carries the vLLM
release, the operator release, the tag and the CPU model.

## 0. Before (nodes off)

- Tag v2.4.1 exists and `gitops/root-app.yaml` points to it. The workflows run
  with `--ref v2.4.1`; the local checkout is `main`, because the A/B
  manifests (`tests/ab/`) and this runbook came after the tag and are applied
  by hand, not by Argo CD.
- Prices read again (BUDGET rule 2): the two `aws pricing` commands of
  [live-a021.md](live-a021.md) section 0. If a price is higher than in the
  BUDGET row, the row is updated before apply.
- Rest of [live.md](live.md) section 0 (CI green on the tag, apply role
  preflight, public IP, Grafana environments, `AWS_ACCOUNT_ID` secret).
- Start time noted. Forced destroy at apply + 2 h.

## 1-4. Apply, GitOps, Grafana secret

[live.md](live.md) sections 1 to 4 with `--ref v2.4.1`. Record for goal 1:

    kubectl -n argocd get applications
    kubectl get validatingpolicy karpenter-config-from-git -o jsonpath='{.status.conditionStatus.ready}{" "}{range .status.conditionStatus.conditions[*]}{.type}={.status}{" "}{end}'; echo
    kubectl get clusterrole kyverno:reports-controller:additional -o jsonpath='{.rules}'; echo
    kubectl get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion

Expected: every application Synced/Healthy (`policies` too), ready `true` and
`RBACPermissionsGranted=True`, the additional role with get/list/watch on
the two Karpenter resources. AMI: the system nodes' image ID, read from EC2,
names release 20261119 (command given in the session, account id masked).

## 5. Run A1: v0.11.2, node chosen by Karpenter

    grep -v 'nodeName: NODE' tests/ab/model-v0.11.2.yaml | kubectl apply -f -

Wait for phase Ready (one replica), then:

- `N` = the pod's node. Annotate it `karpenter.sh/do-not-disrupt=true`:
  `general` consolidates empty nodes after 1 min, and the node is empty
  between two runs.
- Record the node's CPU from inside the pod: `/proc/cpuinfo` model name,
  `amx_bf16` / `avx512f` flags, `lscpu`, and the node's instance type,
  capacity type and zone.
- `kubectl apply -f tests/gameday/probe.yaml` (it calls the same Service).
- 8 minutes of traffic. Times written down: Ready, probe start, end.

## 6. Run B: v0.34.0 on node N

    kubectl -n inference-test delete vllmservice qwen-0-5b-cpu --wait
    sed "s/nodeName: NODE/nodeName: $N/" tests/ab/model-v0.34.0.yaml | kubectl apply -f -

The probe keeps running; its requests fail while no replica is Ready, and
those are outside every window. Wait for Ready, check that the pod is on `N`
and runs the v0.34.0 digest, then 8 minutes of traffic. The first request
after Ready is also the first-request number on v0.34.0 for this node
(A-021 finding 2).

## 7. Run A2: v0.11.2 again on node N

Same as section 6 with `tests/ab/model-v0.11.2.yaml`. 8 minutes.

## 8. Windows and numbers

    kubectl -n inference-test logs deploy/probe --tail=-1 > probe-a022.jsonl

Per run, the window from its first request after Ready to the delete of the
next run: n, failed, first request, p50 and p95 of the rest (command given in
the session, as in A-021), and `scripts/gameday-sli.py` on each window.
Result table: A1, B, A2, B/A1, A2/A1, CPU model.

## 9-10. Destroy and evidence

    kubectl annotate node "$N" karpenter.sh/do-not-disrupt-
    kubectl delete -f tests/gameday/probe.yaml
    kubectl delete namespace inference-test

Then [live.md](live.md) sections 9 and 10 with `--ref v2.4.1`: 0 Karpenter
nodes, NodeClasses deleted, verify-teardown fails as expected, destroy,
TEARDOWN CLEAN, Grafana access policy of the session deleted. Evidence in
`docs/evidence/live-a022-<date>.md`.

## Stop conditions

- Apply + 2 h reached: destroy, whatever is left (runs not done are recorded
  as not done).
- The model node not Ready 20 min after the first VllmService: record, destroy.
- Any application not Healthy 30 min after the root app and the cause not
  found in 15 min: record the diff, go on with goal 2 only if it is not
  `karpenter` or `vllm-coldstart-operator`.
- A run not Ready 15 min after its apply: record, skip to the next run or to
  destroy.
