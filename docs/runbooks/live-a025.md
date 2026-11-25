# Live session A-025: v2.4.3, prefix-aware routing on EKS, S3'' node shutdown

Written 2026-11-25, before the session. One bounded session on release
**v2.4.3** (operator v0.18.0, Session cost tag of v2.4.2). Three goals,
nothing else:

1. **v2.4.x comes up from Git with the Session tag**: every Argo CD
   application Synced and Healthy, `session label: A-025`, every
   EC2NodeClass carrying `Session=A-025`, the operator at v0.18.0. First
   live of v2.4.2 and v2.4.3.
2. **Prefix-aware routing on EKS** (ROADMAP step 5, closes the "only on
   kind" limit of eks #89): protocol, hypotheses E1-E5 and the reading of
   each outcome in [EKS.md](../../experiments/prefix-routing/EKS.md),
   including the llm-d-router #2059 parity on real servers (E3) and the
   Envoy 503 (E5).
3. **S3'' node shutdown on v2.4.3** (ROADMAP step 6): protocol and
   hypotheses in [s3-node-shutdown-v2.4.3.md](../gameday/s3-node-shutdown-v2.4.3.md),
   plus observation O1 of EKS.md (a second probe through the router).

Goal 2 runs before goal 3: S3'' scales Karpenter to 0, and nothing after it
should need a new node. Budget: BUDGET A-025 (platform-notes), at most
2 h 30 min from apply. Steps that are not specific to this session are in
[live.md](live.md) and referenced by number. Every number in the evidence
carries the vLLM release, the router release or commit, the operator
release, the tag and the CPU model.

## 0. Before (nodes off)

- Tag v2.4.3 exists and `gitops/root-app.yaml` points to it. The workflows
  run with `--ref v2.4.3 -f session=A-025`; the local checkout is `main`,
  because the experiment files (`experiments/prefix-routing/eks/`) and this
  runbook came after the tag and are applied by hand, not by Argo CD.
- Prices read again (BUDGET rule 2): the two `aws pricing` commands of
  [live-a021.md](live-a021.md) section 0. If a price is higher than in the
  BUDGET row, the row is updated before apply.
- Tools on the operator's machine: `helm version --short` (3.8 or later,
  for OCI charts), `python3 --version`.
- The llm-d-router chart for arms `legacy` and `ea`, at the commit of
  `versions.env` (`ROUTER_MAIN_COMMIT`):

      git clone -q https://github.com/llm-d/llm-d-router ~/llm-d-router && git -C ~/llm-d-router checkout -q 32a075e25b94ce6657b2ca33584e61a3f09d1d25 && git -C ~/llm-d-router rev-parse HEAD

- Rest of [live.md](live.md) section 0 (CI green on the tag, apply role
  preflight, public IP, Grafana environments, `AWS_ACCOUNT_ID` secret).
- Start time noted. Forced destroy at apply + 2 h 30 min.

## 1-4. Apply, GitOps, Grafana secret

[live.md](live.md) sections 1 to 4 with `--ref v2.4.3` and
`-f session=A-025`; section 3 includes `scripts/label-session.sh`. Record
for goal 1:

    kubectl -n argocd get applications
    kubectl get ec2nodeclass -o custom-columns=NAME:.metadata.name,SESSION:.spec.tags.Session
    kubectl -n vllm-operator-system get deploy -o jsonpath='{..image}'; echo

Expected: every application Synced/Healthy, `Session` A-025 on both
EC2NodeClasses, the operator image of v0.18.0.

## 5. Goal 2: routing arms

    export ROUTER_SRC=~/llm-d-router
    bash experiments/prefix-routing/eks/run.sh backend

Expected within 20 minutes: `qwen-prefix: 2 replicas Ready`, one line per
replica with node, zone (two different zones), instance type, capacity type
and CPU model, and the engine's cache line (136 blocks). Then, unattended,
one line every 10 s, detached from the SSH session (in A-025 a dropped
session stopped a foreground loop at 18:46Z; Ctrl-C stops only `tail`):

    nohup bash experiments/prefix-routing/eks/run.sh all > ~/run-all.log 2>&1 < /dev/null & sleep 2; tail -f ~/run-all.log

After a drop, `tail -f ~/run-all.log` again; if the run itself stopped,
the same `nohup` command resumes from the first run without a summary.

12 runs (4 arms x 3 repetitions) of 160 requests, about 3 to 4 minutes
each with the router install: about 45 minutes. It ends with the table of
`report.py`. If a run fails, the script stops: record the last lines, then
go on with `run.sh arm ARM REP` for the runs left, if time allows (stop
conditions below). Then:

    tar czf a025-routing.tgz -C experiments/prefix-routing/eks results
    bash experiments/prefix-routing/eks/run.sh clean

## 6. Goal 3: S3'' with the router probe

Game day setup of [../gameday/README.md](../gameday/README.md) section 8
(model, Ready, 2 pods on 2 nodes, probe, 5 minutes of 200). Then, **before
Karpenter goes to 0** (the router needs a node of its own):

    bash experiments/prefix-routing/eks/run.sh probe-router up
    kubectl -n inference-test logs deploy/probe-router --tail=5

Then S3'' as written in
[s3-node-shutdown-v2.4.3.md](../gameday/s3-node-shutdown-v2.4.3.md)
(README section 8, S3 commands), with these reads right after
`terminate-instances`, one at a time:

    kubectl get node "$N" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'; echo
    kubectl -n vllm-operator-system logs deploy/vcso-vllm-coldstart-operator --since=2m | grep -i 'leaves the Service'
    kubectl -n inference-test get endpointslices -o yaml | grep -E 'ready:|ip:|nodeName:'

After the restore and both probes at 200 again:

    kubectl -n inference-test logs deploy/probe --tail=-1 > probe-a025.jsonl
    bash experiments/prefix-routing/eks/run.sh probe-router down
    python3 scripts/gameday-sli.py probe-a025.jsonl --from <UTC> --to <UTC>
    python3 scripts/gameday-sli.py experiments/prefix-routing/eks/results/probe-router.jsonl --from <UTC> --to <UTC>

The window is the same for both probes: from `terminate-instances` to
steady state again.

## 7-8. Destroy and evidence

    kubectl delete namespace inference-test

Then [live.md](live.md) sections 9 and 10 with `--ref v2.4.3` and
`-f session=A-025`: 0 Karpenter nodes, NodeClasses deleted,
verify-teardown fails as expected, destroy, TEARDOWN CLEAN, Grafana access
policy of the session deleted. Evidence in
`docs/evidence/live-a025-<date>.md` (goals 1-3, hypotheses E1-E5 and O1,
S3'' hypotheses 1-5). The Session tag is activated in the Billing console
one day after the session ([cost-allocation.md](cost-allocation.md)), so
Cost Explorer can give A-025 its own cost.

## Stop conditions

- Apply + 2 h 30 min reached: destroy, whatever is left (runs not done are
  recorded as not done). Nothing destroys the cluster by itself: in A-025
  the destroy started 45 minutes after this limit. Write the limit time down
  at apply and check the clock before every new step.
- `qwen-prefix` not Ready 20 minutes after `run.sh backend`: record, skip
  goal 2, go to goal 3.
- Goal 2 not finished at apply + 1 h 30 min: stop it after the current run,
  report the repetitions done, go to goal 3 (S3'' needs about 35 minutes).
- Any application not Healthy 30 minutes after the root app and the cause
  not found in 15 minutes: record the diff; goals 2 and 3 go on only if it
  is not `karpenter` or `vllm-coldstart-operator`.
- S3'' abort conditions as in its protocol.
