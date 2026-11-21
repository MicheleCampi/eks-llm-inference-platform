# Live session A-021: current versions, vLLM v0.34.0 cold start on EKS

One bounded session on the release that carries the version upgrades
(Argo CD 3.6.2, External Secrets 2.15.0, Alloy 1.16.0, Karpenter 1.15.3,
vLLM CPU v0.34.0). Two goals, nothing else:

1. **The upgraded platform comes up from Git**: every Argo CD application
   Synced and Healthy, ESO syncs the Grafana secret, Alloy ships metrics,
   Karpenter launches the model nodes.
2. **vLLM v0.34.0 cold start on EKS, same method as the v0.11.2 numbers**:
   image pull time, pod Ready time, first request after Ready, steady p50.
   Baseline on v0.11.2 (re-run of 2026-11-21, v2.3.8): first request after
   Ready 5.84 s, steady p50 3.81 s. CI on v0.34.0 (operator #99): first
   request after Ready 5.26 s, cold without the operator 18.22 s.

No chaos scenarios (budget option A). Budget: BUDGET A-021, ceiling
2.50 EUR, at most 2 h from apply. Steps that are not specific to this
session are in [live.md](live.md) and referenced by number.

## 0. Before (nodes off)

- The release tag exists (Michele creates it) and `gitops/root-app.yaml`
  points to it. Below, `TAG` is that tag.
- Prices read again (BUDGET rule 2), one command at a time:

      aws pricing get-products --region us-east-1 --service-code AmazonEC2 --filters Type=TERM_MATCH,Field=instanceType,Value=m7i-flex.large Type=TERM_MATCH,Field=location,Value="EU (Ireland)" Type=TERM_MATCH,Field=operatingSystem,Value=Linux Type=TERM_MATCH,Field=tenancy,Value=Shared Type=TERM_MATCH,Field=preInstalledSw,Value=NA Type=TERM_MATCH,Field=capacitystatus,Value=Used --query 'PriceList[0]' --output text | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD'

  If a price is higher than in the BUDGET row, the row is updated before apply.
- AMI (optional, not blocking): the pins say `al2023@v20261107`. Newer
  releases exist; moving needs both pins in one commit, so it is not done
  in this session.

      aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/recommended/release_version --query Parameter.Value --output text

- Rest of [live.md](live.md) section 0 (CI green on the tag, apply role
  preflight, public IP, Grafana environments, `AWS_ACCOUNT_ID` secret).
- Start time noted. Forced destroy at apply + 2 h.

## 1-4. Apply, GitOps, Grafana secret

[live.md](live.md) sections 1 to 4 with `--ref TAG`. Record for goal 1:

    kubectl -n argocd get applications
    kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
    kubectl -n external-secrets get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
    kubectl -n monitoring get externalsecret grafana-cloud-credentials

Expected: every application Synced/Healthy, Argo CD `v3.6.2`, ESO `v2.15.0`,
ExternalSecret READY True. If `root` is OutOfSync, follow live.md section 3
before anything else: Argo CD 3.6 now diffs ServerSideApply apps on the API
server (Server-Side Diff), a new code path for this platform.

## 5. Model on vLLM v0.34.0

    kubectl apply -f tests/gameday/model.yaml
    kubectl -n inference-test get vllmservice qwen-0-5b-cpu -w

Two replicas, zone spread Required, Karpenter launches two nodes. When the
phase is Ready (both replicas), record per pod:

    kubectl -n inference-test get events --sort-by=.lastTimestamp | grep -E 'Scheduled|Pulled|Started|Unhealthy' | tail -20
    kubectl -n inference-test get pods -o json | jq -r '.items[] | [.metadata.name, .spec.nodeName, .metadata.creationTimestamp, (.status.conditions[] | select(.type=="Ready") | .lastTransitionTime)] | @tsv'
    kubectl -n inference-test get pods -o jsonpath='{.items[0].spec.containers[0].image}'; echo

Expected: image `vllm-openai-cpu:v0.34.0-x86_64@sha256:b14c3a46…`; the
"Successfully pulled image ... in X" lines give the pull time (1.80 GB
compressed, was 1.12 GB on v0.11.2).

## 6. First request after Ready, then steady state

Start the probe right after the phase is Ready:

    kubectl apply -f tests/gameday/probe.yaml
    kubectl -n inference-test logs deploy/probe -f | head -5

The first lines are the first client requests after Ready. Objective: under
8 s (CI on v0.34.0: 5.26 s). Then 10 minutes of steady traffic and:

    kubectl -n inference-test logs deploy/probe --tail=-1 > probe-a021.jsonl
    python3 scripts/gameday-sli.py probe-a021.jsonl

Record p50, p95, availability. Compare with v0.11.2 (p50 3.81 s).

## 7. One fresh replica under traffic (optional, if time allows)

    kubectl -n inference-test delete pod "$(kubectl -n inference-test get pods -l app=qwen-0-5b-cpu -o name | head -1 | cut -d/ -f2)"

The replacement must reach Ready and the probe must show no request at
8 s or more after it joins the Service (warm Ready on v0.34.0 in eager mode).

## 8-10. Destroy and evidence

[live.md](live.md) sections 9 and 10, with `kubectl delete -f
tests/gameday/probe.yaml -f tests/gameday/model.yaml` first. Evidence in
`docs/evidence/live-a021-<date>.md`: every number with **vLLM v0.34.0** and
the tag written next to it.

## Stop conditions

- Apply + 2 h reached: destroy, whatever is left.
- A model node not Ready 20 min after the VllmService: record, destroy.
- Any application not Healthy 30 min after the root app and the cause not
  found in 15 min: record the diff, destroy.
