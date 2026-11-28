# Live session A-027: S3'' node shutdown on v2.4.3, the only goal

Written 2026-11-28, before the session. One short session on release
**v2.4.3** (operator v0.18.0), as A-025 and A-026. Nothing in `gitops/`,
`terraform/` or the operator changed since the tag, so the workflows run
with `--ref v2.4.3 -f session=A-027` and the local checkout is `main`.

**One goal: S3''**, deferred from A-025 and again from A-026 (time). The
protocol and hypotheses 1-5 are in
[s3-node-shutdown-v2.4.3.md](../gameday/s3-node-shutdown-v2.4.3.md); the
second probe through the router (observation O1 of
[prefix-routing/EKS.md](../../experiments/prefix-routing/EKS.md)) runs
alongside it and never delays it. A-026 finding 1: S3'' needs about
40 minutes from the model apply to steady state after the restore, so it
does not fit as the second goal of a 2-hour session. Here it is the first
and only one.

Budget: BUDGET A-027 (platform-notes), at most **2 h 00 min from apply**.
Steps that are not specific to this session are in [live.md](live.md),
referenced by number.

## The clock

Printed once when the apply is approved:

    read -rp 'Apply approved at (UTC, HH:MM): ' T; T0=$(date -u -d "today $T" +%s); for s in "S3'' set-up start:40" "terminate-instances by:70" "teardown start:90" "destroy dispatched:100" "LIMIT:120"; do printf '%-24s %s UTC\n' "${s%:*}" "$(date -u -d @$((T0 + ${s##*:} * 60)) +%H:%M)"; done

Rules, written before the session:

- Before every new step, compare the clock with the table. A step that
  would start after its time is skipped and recorded as not done; the
  protocol is never shortened to fit (D-0175).
- **S3'' not at `terminate-instances` by apply + 1 h 10 min**: not done,
  teardown at once.
- **Teardown starts at apply + 1 h 30 min whatever is running**: that leaves
  30 minutes for the destroy (14 min in A-025; 34 min in A-026, finding 2).
- The agent sets two reminders in the thread: apply + 1 h 10 min and
  apply + 1 h 30 min.

Expected timeline (S3' of 2026-11-21: page 7 min after the scale to 0,
ticket 8 min after the eviction, restore in 2 min 53 s):

| From apply | Step |
|---|---|
| + 40 min | model applied (sections 1-4 done) |
| + 45 | 2 replicas Ready on 2 nodes, probe started |
| + 50 | 5 minutes of 200: steady state; router probe up |
| + 52 | self-heal off, Karpenter to 0 |
| + 60 | page received, `terminate-instances`, reads |
| + 70 | ticket received, restore from Git |
| + 80 | both probes at 200 again, SLIs, teardown |

## 0. Before (nodes off)

- `git -C ~/eks pull` on `main`; `python3 -c 'import yaml'`; `helm version --short`.
- `~/llm-d-router` at the commit of `versions.env` (the router probe):

      git -C ~/llm-d-router fetch -q origin && git -C ~/llm-d-router checkout -q 32a075e25b94ce6657b2ca33584e61a3f09d1d25 && git -C ~/llm-d-router rev-parse HEAD

- Prices read again (BUDGET rule 2); rest of [live.md](live.md) section 0.
- A Grafana Cloud access policy for this session (`eks-a027`, scope
  `metrics:write`, expiry 1 day), made just before section 4.

## 1-4. Apply, GitOps, Grafana secret (target: apply + 40 min)

[live.md](live.md) sections 1 to 4 with `--ref v2.4.3` and
`-f session=A-027`. Then the clock command above. Record, one command:

    kubectl -n argocd get applications && kubectl get ec2nodeclass -o custom-columns=NAME:.metadata.name,SESSION:.spec.tags.Session

Expected: every application Synced/Healthy, `Session` A-027 on both
EC2NodeClasses.

## 5. S3'' (apply + 40 to + 90 min)

Each line is one command; the operator writes the UTC time of each.

Model and steady state ([../gameday/README.md](../gameday/README.md)
section 8):

    cd ~/eks && kubectl apply -f tests/gameday/model.yaml && until [ "$(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu --no-headers 2>/dev/null | grep -c ' 1/1 ')" = 2 ]; do echo "$(date -u +%T) $(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu --no-headers 2>/dev/null | awk '{print $2}' | paste -sd' ')"; sleep 15; done && kubectl -n inference-test get pods -o wide && kubectl apply -f tests/gameday/probe.yaml

Expected: 2 pods on 2 different nodes. Then 5 minutes of code 200, and the
router probe started in the same 5 minutes (it needs a Karpenter node of
its own, so it goes up before Karpenter goes to 0):

    cd ~/eks && export ROUTER_SRC=~/llm-d-router && bash experiments/prefix-routing/eks/run.sh probe-router up && for i in $(seq 1 20); do echo "$(date -u +%T) probe: $(kubectl -n inference-test logs deploy/probe --since=15s | grep -c '"code":200') ok, router: $(kubectl -n inference-test logs deploy/probe-router --since=15s 2>/dev/null | grep -c '"code":200') ok"; sleep 15; done

If `probe-router up` fails, record it and go on without O1.

Autoscaler down (README section 8, S3), then wait for the page
(`KarpenterControllerUnavailable` by email, about 7 minutes):

    cd ~/eks && kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}' && kubectl -n argocd patch application karpenter --type merge -p '{"spec":{"syncPolicy":null}}' && kubectl -n kube-system scale deploy/karpenter --replicas=0 && echo "Karpenter 0 at $(date -u +%T)Z"

After the page, the injection and the reads of hypotheses 1 and 2, in one
command (the node's Ready message every 5 s for 60 s, then the operator
log and the EndpointSlice):

    cd ~/eks && N=$(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu -o jsonpath='{.items[0].spec.nodeName}') && I=$(kubectl get node "$N" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}') && echo "$N $I" && aws --region eu-west-1 ec2 terminate-instances --instance-ids "$I" --query 'TerminatingInstances[0].CurrentState.Name' --output text && echo "terminate at $(date -u +%T)Z" && for i in $(seq 1 12); do echo "$(date -u +%T) $(kubectl get node "$N" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].message}')"; sleep 5; done; kubectl -n vllm-operator-system logs deploy/vcso-vllm-coldstart-operator --since=3m | grep -i 'leaves the Service'; kubectl -n inference-test get pods -o wide; kubectl -n inference-test get endpointslices -o yaml | grep -E 'ready:|ip:|nodeName:'

Hypothesis 4, until the ticket (`ModelReplicasBelowSpec`, 5 to 7 minutes
after the pod is gone): the replacement stays Pending with no node.

    cd ~/eks && for i in $(seq 1 40); do echo "$(date -u +%T) $(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu --no-headers -o wide | awk '{print $1" "$3" "$7}' | paste -sd' ')"; sleep 15; done

Ctrl-C when the ticket arrives. Restore from Git (hypothesis 5), then wait
for 2 replicas Ready again:

    cd ~/eks && kubectl apply -f gitops/root-app.yaml && echo "restore at $(date -u +%T)Z" && until [ "$(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu --no-headers | grep -c ' 1/1 ')" = 2 ]; do echo "$(date -u +%T) $(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu --no-headers -o wide | awk '{print $2" "$3" "$7}' | paste -sd' ')"; sleep 15; done && kubectl get nodes -L topology.kubernetes.io/zone && echo "2 Ready at $(date -u +%T)Z"

SLIs over the same window for both probes, from `terminate-instances` to
steady state again (typed, not edited into the command):

    read -rp 'S3 window from (UTC, YYYY-MM-DDTHH:MM:SSZ): ' F; read -rp 'to: ' U; cd ~/eks && kubectl -n inference-test logs deploy/probe --tail=-1 > probe-a027.jsonl && bash experiments/prefix-routing/eks/run.sh probe-router down && python3 scripts/gameday-sli.py probe-a027.jsonl --from "$F" --to "$U" && python3 scripts/gameday-sli.py experiments/prefix-routing/eks/results/probe-router.jsonl --from "$F" --to "$U" && tar czf ~/a027-s3.tgz probe-a027.jsonl -C experiments/prefix-routing/eks results

## 6-7. Teardown (from apply + 1 h 30 min at the latest)

    cd ~/eks && kubectl delete namespace inference-test --ignore-not-found && kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}' && kubectl -n argocd patch application karpenter-nodes --type merge -p '{"spec":{"syncPolicy":null}}' && kubectl delete nodepool general gpu && until [ "$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)" = 0 ]; do echo "$(date -u +%T) nodeclaims: $(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)"; sleep 15; done && echo "NODECLAIMS 0"

Then [live.md](live.md) sections 9 and 10 with `--ref v2.4.3` and
`-f session=A-027`: EC2NodeClasses, `verify-teardown.sh` with LEFT lines,
destroy, approval, TEARDOWN CLEAN (it now also counts the VPC, the VPC CNI
ENIs and the cluster security group; on `DependencyViolation`, live.md
section 10). Grafana access policy `eks-a027` deleted. Evidence in
`docs/evidence/live-a027-<date>.md` (hypotheses 1-5, O1), raw files in
`docs/evidence/data/`.

## Stop conditions

- **Apply + 1 h 30 min**: teardown starts, whatever is running.
- **Apply + 1 h 10 min** and no `terminate-instances` yet: S3'' not done.
- 2 replicas not Ready 20 minutes after the model apply: record, teardown.
- No page 15 minutes after Karpenter to 0: record it (hypothesis of the
  alert refuted) and inject anyway, if the clock allows.
- Any application not Healthy 30 minutes after the root app and the cause
  not found in 15 minutes: record the diff; S3'' goes on only if it is not
  `karpenter` or `vllm-coldstart-operator`.
- S3'' abort conditions as in its protocol.
