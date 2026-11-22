# Live session runbook

One bounded session that proves what CI cannot: apply through the pipeline,
Grafana as code, Karpenter scaling, the CPU-limit alert by email, consolidation,
admission policies, then a clean destroy. Everything billable exists only
between step 2 and step 9.

## 0. Before

- The BUDGET entry of the session confirmed for the release being applied
  (v2.3.5 ran game day #1 under BUDGET A-019, v2.3.8 the re-run under A-020; v2.4.0 (current versions: Argo CD 3.6.2, ESO 2.15, Alloy 1.16, Karpenter 1.15.3, operator v0.17.0, vLLM CPU v0.34.0) ran under A-021, see [live-a021.md](live-a021.md); v2.4.1 (Kyverno reports RBAC fix, AMI 1.36.5-20261119) runs under A-022, see [live-a022.md](live-a022.md)).
- `bash ci/validate.sh` is ALL PASS on the tag.
- `bash ci/simulate-apply-role.sh` is PREFLIGHT PASS (administrator credentials,
  read-only): the apply role can do what apply and destroy need, and no more.
- Your public IP has not changed since `PUBLIC_ACCESS_CIDRS` was set; if it
  has, set it again in both environments `live-plan` and `live`.
- Environments `grafana-plan` and `grafana` hold `GRAFANA_URL`,
  `GRAFANA_PROM_DATASOURCE_UID`, `AWS_GRAFANA_ROLE_ARN` (variables) and
  `GRAFANA_TOKEN`, `ALERT_EMAIL` (secrets): Viewer token and plan role in
  `grafana-plan`, writer token and apply role in `grafana`.
- Repository secret `AWS_ACCOUNT_ID` exists (`gh secret list`): every AWS job
  fails at its first step without it, because masking the account id from the
  first log line depends on it (`ci/check-account-mask.py`).
- Start time noted; forced destroy at the limit of the BUDGET entry, counted
  from apply (A-016: 3 hours; A-017: 4 hours).

## 1. Check out the release

    git checkout v2.4.1

Read this runbook from main: commits after v2.4.1 change documentation only.

## 2. Apply through the pipeline

    gh workflow run apply.yml --ref v2.4.1
    gh run watch

Open the run: the plan job summary shows the plan and its sha256. Expected:
only creates. Approve in "Review deployments" (environment `live`). The apply
job re-plans and applies only if the sha256 is the approved one. Then, locally:

    terraform init && $(terraform output -raw configure_kubectl)
    kubectl get nodes

## 3. GitOps bootstrap

Follow README "Run it": Argo CD (`kubectl apply -k gitops/argocd
--server-side`), `projects.yaml`, then the root app. Wait until every Argo CD
application is Synced and Healthy.

    kubectl -n argocd get applications

`root` must be Synced too. Live #3 and #4 saw it OutOfSync with every child
Synced/Healthy: Argo CD adds `pre-delete-finalizer.argocd.argoproj.io` (and
`.../cleanup`) to the `kyverno` Application, whose chart has a pre-delete
hook, and Git does not declare them (live #4, README Findings #8). Since
v2.3.3 `root` ignores exactly those finalizers. If `root` is OutOfSync again,
record which resource and which field before anything else (the cause is in
the diff, not in the children):

    kubectl -n argocd get application root -o json | jq -r '.status.resources[] | select(.status != "Synced") | "\(.kind)/\(.name) \(.status)"'

Then compare that resource's live YAML (`kubectl get <kind> <name> -o yaml`,
`metadata` included) with its file under `gitops/apps/` and record the
differing field.

## 4. Grafana as code and the secret

Terraform creates `llm-inference/grafana-cloud-remote-write` empty, so its
value is never in state. Put it before anything reads it (live #3: without
it ESO reported `SecretSyncedError` and Alloy `CreateContainerConfigError`).
Use a token of a Grafana Cloud access policy made for this session only
(scope `metrics:write`, expiry 1 day) and delete the policy after step 9.
The token is typed, never pasted in a file or a chat:

    read -rsp 'Grafana token: ' T; echo
    jq -n --arg url "$PROM_URL" --arg user "$PROM_USER" --arg token "$T" '{url:$url,user:$user,token:$token}' | aws secretsmanager put-secret-value --secret-id llm-inference/grafana-cloud-remote-write --secret-string file:///dev/stdin --query Name; unset T
    kubectl -n monitoring annotate externalsecret grafana-cloud-credentials force-sync=$(date +%s) --overwrite

`PROM_URL` is the remote-write URL and `PROM_USER` the instance id of the
Prometheus data source (Grafana Cloud, stack details).

    gh workflow run observability.yml --ref v2.4.1
    gh run watch

Approve in environment `grafana`. Expected: folder, two dashboards, contact
point, notification policy created; three rules in namespace
`karpenter-rules`, shown as Provisioned in Grafana.

    kubectl -n monitoring get externalsecret grafana-cloud-credentials
    kubectl -n monitoring get secret grafana-cloud-credentials -o json | jq '.data | keys'

Expected: READY True; keys `token`, `url`, `user` (values are never printed).
In Grafana, Karpenter metrics arrive within a few minutes.

## 5. Karpenter scale-out and the CPU-limit alert

    kubectl apply -f tests/live/inflate.yaml
    kubectl -n karpenter-test scale deploy/inflate --replicas=5
    kubectl get nodeclaims -w

Each pod asks 1 CPU and only one fits a 2 vCPU node; the limit of NodePool
`general` is `cpu: "8"`. Expected: four NodeClaims, four pods Running, the fifth Pending.
After 5 minutes `KarpenterNodePoolCpuLimitReached` fires and the email
arrives at `ALERT_EMAIL`; after 15 minutes `KarpenterPodsUnschedulable`
fires for the fifth pod.

    kubectl get nodes -L topology.kubernetes.io/zone,karpenter.sh/capacity-type

Expected: nodes in more than one zone; capacity type as the NodePool allows
(spot or on-demand), recorded in the evidence.

## 6. Requests against real usage

    kubectl top pods -A --sort-by=cpu | head -15
    kubectl -n karpenter-test get deploy inflate -o jsonpath='{..resources.requests}'

Expected: inflate uses far less CPU than the 1 CPU it requests. The
rightsizing dashboard shows the same gap per namespace (showback).

## 7. Hardening seen live

    kubectl -n monitoring get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,USER:.spec.securityContext.runAsUser,NONROOT:.spec.securityContext.runAsNonRoot
    kubectl auth can-i get secrets -A --as=system:serviceaccount:monitoring:alloy
    kubectl -n argocd get pods -o custom-columns=NAME:.metadata.name,NONROOT:.spec.securityContext.runAsNonRoot

Expected: Alloy runs as UID 473, non-root; `can-i` answers `no`; every Argo
CD pod non-root. ESO READY True in step 4 proves Pod Identity
(`pods.eks.amazonaws.com`) for `external-secrets/external-secrets`.

## 8. Consolidation and admission policies

    kubectl -n karpenter-test scale deploy/inflate --replicas=0
    kubectl get nodeclaims -w
    kubectl apply --dry-run=server -f ci/fixtures/kyverno/privileged.yaml

Expected: empty nodes removed by Karpenter; the alert resolves; the
privileged pod rejected by the ValidatingPolicy, same reason as in CI.

## 9. Destroy

Root app and karpenter-nodes sync with selfHeal: a deleted NodePool would be
recreated within seconds. Stop automated sync first, then delete the
NodePool: Karpenter drains and terminates its nodes before the cluster goes.
Then delete the EC2NodeClass: Karpenter owns the instance profile it made for
the node role, and the apply role may not remove it (live attempt 2).

    kubectl delete -f tests/live/inflate.yaml
    kubectl -n argocd patch application "$(yq .metadata.name gitops/root-app.yaml)" --type merge -p '{"spec":{"syncPolicy":null}}'
    kubectl -n argocd patch application karpenter-nodes --type merge -p '{"spec":{"syncPolicy":null}}'
    kubectl delete nodepool general gpu
    kubectl get nodeclaims -w        # wait until empty
    kubectl delete ec2nodeclass default gpu   # Karpenter deletes the instance profile it created
    kubectl wait --for=delete ec2nodeclass/default ec2nodeclass/gpu --timeout=300s
    scripts/verify-teardown.sh       # must exit 1 with LEFT lines: proves the check sees live resources
    gh workflow run destroy.yml --ref v2.4.1

Approve the destroy plan in environment `live`. Grafana objects cost nothing
and stay for the next session; the session's access policy (step 4) is deleted.

## 10. Verify nothing billable is left, then evidence

    scripts/verify-teardown.sh

Must print TEARDOWN CLEAN; any LEFT line is deleted by hand and the script is
run again. Then write `docs/evidence/live-<date>.md`: commands, outputs
(account id and IP masked), the alert email (headers only), what passed and
what did not.
