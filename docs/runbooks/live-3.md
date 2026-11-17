# Live #3 runbook: Karpenter under real disruption, and a real model

NOT YET RUN. Runs after `docs/runbooks/live.md` steps 0-8 on the same
session, before its step 9 (destroy). It proves what attempt 2 (2026-11-15)
did not: a Spot interruption handled end to end (warning injected on the
real queue, since this account has no FIS), drift within budgets, the PodDisruptionBudget
honoured during a drain, IMDS blocked from a pod, and a model served by the
operator on EKS. Every result goes to `docs/evidence/live-<date>.md`.

## 0. Before (no spend)

- A new BUDGET entry for live #3, with its cap, approved before step 2 of
  `live.md`. Done: A-017, cap 4,00 EUR, at most 4 hours from apply
  (approved 2026-11-17).
- `bash ci/simulate-apply-role.sh` PREFLIGHT PASS after the bootstrap change
  of this release (PassRole to `fis.amazonaws.com`), applied by hand in
  `bootstrap/ci-identity`.
- The CPU image pre-check on a machine with Docker and 8 GB of RAM, free:
  the same command, env and 6 GB limit the operator gives the pod
  (`tests/live/inference-cpu.yaml`). If it does not answer, step 2 is skipped
  and the reason recorded. Done 2026-11-17 (`--memory 6g --cpus 2`): startup
  complete, KV cache 349,440 tokens, HTTP 200, 4.88 GiB used, 3.9 s for 32
  tokens warm. It needed operator `v0.12.0`: `v0.11.0` gave every `gpu: 0`
  service the inert placeholder pod.
- Drift is blocked 08:00-18:00 UTC on weekdays (`nodepool-general.yaml`):
  step 4 runs outside that window, or records that the budget held.

## 1. IMDS from a pod

    kubectl apply -f tests/live/inflate.yaml
    kubectl -n karpenter-test scale deploy/inflate --replicas=3
    kubectl apply -f tests/live/imds-probe.yaml
    kubectl -n karpenter-test logs pod/imds-probe

Expected: `IMDS BLOCKED`.

## 2. A real model through the operator

    kubectl apply -f tests/live/inference-cpu.yaml
    kubectl get nodeclaims -o wide -w
    kubectl -n inference-test get vllmservice qwen-0-5b-cpu -w

Expected: a NodeClaim of type `m7i-flex.large` (the only free-tier type with
room for 6Gi), the VllmService Ready; record the time from apply to Ready.

    kubectl -n inference-test port-forward svc/qwen-0-5b-cpu 8000:8000
    for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' localhost:8000/v1/completions -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","prompt":"Kubernetes is","max_tokens":32}'; done

Expected: 20 answers 200; record p50 and max. CPU latency, not a GPU benchmark.

## 3. Spot interruption and the PDB (warning injected on the real queue)

AWS FIS is not available on this account (AWS Free Plan:
`SubscriptionRequiredException`, checked 2026-11-17), so `fis_enabled` is
false and no FIS template exists. The warning AWS would send is injected
instead, shaped exactly as EventBridge delivers it, on Karpenter's real SQS
queue; the rest of the path is the production one.

    kubectl -n karpenter-test get pdb inflate -w &
    bash tests/live/spot-interruption.sh
    kubectl get nodeclaims -w

Expected: within a minute Karpenter reads the warning from its queue
(`karpenter_interruption_received_messages_total{message_type="spot_interrupted"}`
+1, `KarpenterSpotInterruption` fires, ticket), cordons and drains the node
with at most one inflate pod unavailable at a time (`ALLOWED DISRUPTIONS`
never below 0), launches a replacement NodeClaim and terminates the old
instance itself. If the node held the model, record how long it was not
Ready (one replica, no PDB: an expected outage). Not proven here: that AWS
emits the warning and reclaims the instance; on an account with FIS, set
`fis_enabled = true` and run the template of `modules/eks/chaos.tf` instead.

## 4. Drift within the budget

Turn off selfHeal of `karpenter-nodes`, then change the NodeClass so that
every node drifts, as an AMI bump would:

    kubectl -n argocd patch application karpenter-nodes --type merge -p '{"spec":{"syncPolicy":null}}'
    kubectl patch ec2nodeclass default --type merge -p '{"spec":{"tags":{"DriftTest":"live3"}}}'
    kubectl get nodeclaims -o custom-columns=NAME:.metadata.name,DRIFTED:.status.conditions[?(@.type==\"Drifted\")].status -w

Expected: outside the blocked window, nodes replaced at most 20% at a time;
inside it, `Drifted=True` and no replacement. Then restore with
`kubectl -n argocd patch application karpenter-nodes --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'`.

## 5. Then

`live.md` step 9, with `kubectl delete -f tests/live/inference-cpu.yaml -f
tests/live/imds-probe.yaml` first. `scripts/verify-teardown.sh` also checks
that no FIS experiment is running and no FIS template is left (0 on an
account without FIS).
