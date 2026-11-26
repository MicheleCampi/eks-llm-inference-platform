# Live session A-026: v2.4.3, the keep-alive fix on EKS, S3'' node shutdown

Written 2026-11-26, before the session. One bounded session on release
**v2.4.3** (operator v0.18.0), the release of A-025: nothing in `gitops/`,
`terraform/` or the operator changed since, so there is no new tag. The
workflows run with `--ref v2.4.3 -f session=A-026`; the local checkout is
`main` (experiments applied by hand). Two goals, nothing else:

1. **E5 on EKS: the keep-alive race and its fix** (eks #97): protocol and
   hypotheses K6-K7 in
   [keepalive-race/EKS.md](../../experiments/keepalive-race/EKS.md).
2. **S3'' node shutdown on v2.4.3**, deferred from A-025: protocol and
   hypotheses 1-5 in [s3-node-shutdown-v2.4.3.md](../gameday/s3-node-shutdown-v2.4.3.md),
   plus observation O1 of [prefix-routing/EKS.md](../../experiments/prefix-routing/EKS.md)
   (a second probe through the router, now with the 4 s idle timeout).

Goal 1 runs before goal 2: S3'' scales Karpenter to 0, and nothing after it
should need a new node. Budget: BUDGET A-026 (platform-notes), at most
**2 h 30 min from apply**. Steps that are not specific to this session are
in [live.md](live.md) and [live-a025.md](live-a025.md), referenced by number.

## The clock (A-025 finding 1)

A-025 ended about 1 hour after its limit: nothing destroys the cluster by
itself, and the limit was not checked at each step. Here every step has an
**absolute time**, printed once when the apply is approved:

    read -rp 'Apply approved at (UTC, HH:MM): ' T; T0=$(date -u -d "today $T" +%s); for s in "E5 start:40" "E5 end, S3'' start:80" "S3'' end, teardown start:120" "destroy dispatched:130" "LIMIT:150"; do printf '%-28s %s UTC\n' "${s%:*}" "$(date -u -d @$((T0 + ${s##*:} * 60)) +%H:%M)"; done

Rules, written before the session:

- Before every new step, compare the clock with the table. A step that would
  start after its time is skipped and recorded as not done.
- **Teardown starts at apply + 2 h 00 min whatever is running** (step 7):
  that leaves 30 minutes for the destroy (14 min in A-025) and the check.
- The agent sets two reminders in the thread: apply + 1 h 45 min and
  apply + 2 h 00 min.
- Long loops run under `nohup` with a log file; after an SSH drop,
  `tail -f` the log again.

## 0. Before (nodes off, the evening before)

- `git -C ~/eks pull` on `main`; `python3 -c 'import yaml'` (the Envoy patch
  needs PyYAML); `helm version --short` (3.8 or later).
- `~/llm-d-router` at the commit of `versions.env`:

      git -C ~/llm-d-router fetch -q origin && git -C ~/llm-d-router checkout -q 32a075e25b94ce6657b2ca33584e61a3f09d1d25 && git -C ~/llm-d-router rev-parse HEAD

- Prices read again (BUDGET rule 2): the two `aws pricing` commands of
  [live-a021.md](live-a021.md) section 0.
- Rest of [live.md](live.md) section 0 (CI green on the tag, apply role
  preflight, public IP, Grafana environments, `AWS_ACCOUNT_ID` secret).

## 1-4. Apply, GitOps, Grafana secret (target: apply + 40 min)

[live.md](live.md) sections 1 to 4 with `--ref v2.4.3` and
`-f session=A-026`, as in A-025. Then the clock command above. Record:

    kubectl -n argocd get applications
    kubectl get ec2nodeclass -o custom-columns=NAME:.metadata.name,SESSION:.spec.tags.Session

Expected: every application Synced/Healthy, `Session` A-026 on both
EC2NodeClasses.

## 5. Goal 1: the keep-alive race on EKS (apply + 40 to + 80 min)

    cd ~/eks && export ROUTER_SRC=~/llm-d-router && bash experiments/keepalive-race/eks/run.sh backend

Expected within 20 minutes: `qwen-race: 1 replica Ready in race-chart and
race-idle`, one line per replica with node, zone, instance type, capacity
type, CPU model, and `keep-alive: 5 s`. Then both arms at once, about
20 minutes, detached from SSH (Ctrl-C stops only `tail`):

    cd ~/eks && export ROUTER_SRC=~/llm-d-router && nohup bash experiments/keepalive-race/eks/run.sh arms > ~/a026-race.log 2>&1 < /dev/null & sleep 2; tail -f ~/a026-race.log

It ends with one summary line per arm (`eks-chart`, `eks-idle`) and every
failure with its Envoy flag. Then:

    cd ~/eks && tar czf ~/a026-race.tgz -C experiments/keepalive-race/eks results && bash experiments/keepalive-race/eks/run.sh clean

## 6. Goal 2: S3'' with the router probe (apply + 80 to + 120 min)

As [live-a025.md](live-a025.md) section 6, unchanged: game day set-up of
[../gameday/README.md](../gameday/README.md) section 8 (model, Ready, 2 pods
on 2 nodes, probe, 5 minutes of 200), then **before Karpenter goes to 0**:

    cd ~/eks && export ROUTER_SRC=~/llm-d-router && bash experiments/prefix-routing/eks/run.sh probe-router up

(it now patches the 4 s idle timeout, and prints it), then S3'' with the
reads right after `terminate-instances`. Windows for the SLIs, typed, not
edited into the command:

    read -rp 'S3 window from (UTC, YYYY-MM-DDTHH:MM:SSZ): ' F; read -rp 'to: ' U; cd ~/eks && kubectl -n inference-test logs deploy/probe --tail=-1 > probe-a026.jsonl && bash experiments/prefix-routing/eks/run.sh probe-router down && python3 scripts/gameday-sli.py probe-a026.jsonl --from "$F" --to "$U" && python3 scripts/gameday-sli.py experiments/prefix-routing/eks/results/probe-router.jsonl --from "$F" --to "$U"

If S3'' has not reached `terminate-instances` by apply + 1 h 45 min, it is
stopped there and recorded as not done.

## 7-8. Teardown (from apply + 2 h 00 min at the latest)

    kubectl delete namespace inference-test --ignore-not-found; bash ~/eks/experiments/keepalive-race/eks/run.sh clean

Then [live.md](live.md) sections 9 and 10 with `--ref v2.4.3` and
`-f session=A-026`, as A-025 did them: Argo CD sync off, NodePools deleted,
0 NodeClaims, EC2NodeClasses deleted, verify-teardown with LEFT lines,
destroy, approval, TEARDOWN CLEAN, Grafana access policy of the session
deleted. Evidence in `docs/evidence/live-a026-<date>.md` (goals 1-2, K6-K7,
S3'' hypotheses 1-5, O1). The Session tag (activated after A-025) gives
A-026 its own cost in Cost Explorer the next day.

## Stop conditions

- **Apply + 2 h 00 min**: teardown starts, whatever is running.
- `qwen-race` not Ready 20 minutes after `backend`: record, skip goal 1, go
  to goal 2.
- Goal 1 not finished at apply + 1 h 20 min: stop the clients, save what
  is there (`run.sh report`), go to goal 2.
- Any application not Healthy 30 minutes after the root app and the cause
  not found in 15 minutes: record the diff; goals go on only if it is not
  `karpenter` or `vllm-coldstart-operator`.
- S3'' abort conditions as in its protocol.
