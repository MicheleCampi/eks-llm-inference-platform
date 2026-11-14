# Live session runbook

One bounded session that proves what CI cannot: apply, Karpenter scaling and
consolidation, admission policies, alerts, then a clean destroy. Everything
billable exists only between step 2 and step 8.

## 0. Before

- A-016 confirmed for the release being applied (v2.1.0).
- `bash ci/validate.sh` is ALL PASS on the tag; the PR plan shows only creates.
- Start time noted; hard stop at 2 hours, destroy included.

## 1. Check out the release

    git checkout v2.1.0

## 2. Apply

    terraform init && terraform apply
    $(terraform output -raw configure_kubectl)
    kubectl get nodes

## 3. GitOps bootstrap

Follow README "Run it": `projects.yaml`, then the root app. Wait until every
Argo CD application is Synced and Healthy.

## 4. Karpenter scale-out

    kubectl apply -f tests/live/inflate.yaml
    kubectl -n karpenter-test scale deploy/inflate --replicas=5
    kubectl get nodeclaims -w

Expected: new NodeClaims from NodePool `default`, nodes Ready, pods Running,
spread across zones.

## 5. Consolidation

    kubectl -n karpenter-test scale deploy/inflate --replicas=0
    kubectl get nodeclaims -w

Expected: the empty nodes are removed by Karpenter.

## 6. Admission policies

    kubectl apply --dry-run=server -f ci/fixtures/kyverno/privileged.yaml

Expected: rejected by the ValidatingPolicy, same reason as in CI.

## 7. Evidence

Write `docs/evidence/live-<date>.md`: commands run, outputs (account id
masked), what passed, what did not.

## 8. Destroy

Remove workloads first, so Karpenter deletes its own nodes before the cluster
goes away:

    kubectl delete -f tests/live/inflate.yaml
    kubectl get nodeclaims           # wait until empty
    scripts/verify-teardown.sh       # must exit 1 with LEFT lines: proves the check sees live resources
    terraform destroy

## 9. Verify nothing billable is left

    scripts/verify-teardown.sh

Must print TEARDOWN CLEAN. Any LEFT line is deleted by hand and the script is
run again before the session is closed.
