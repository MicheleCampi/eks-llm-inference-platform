#!/usr/bin/env bash
# GitOps bootstrap, after the root app (docs/runbooks/live.md step 3): give
# Argo CD's in-cluster cluster secret the label of this live session, so
# ApplicationSet karpenter-nodes generates the NodePools and tags every
# Karpenter node with Session (gitops/apps/karpenter-nodes.yaml).
# The value is read from the EKS cluster's own Session tag (set by Terraform
# from the input of apply.yml), not typed: one source for both.
# Prints the session only. Idempotent.
set -euo pipefail
C="${1:-llm-inference}"; R="${AWS_REGION:-eu-west-1}"
s=$(aws --region "$R" eks describe-cluster --name "$C" --query 'cluster.tags.Session' --output text)
[[ "$s" =~ ^A-[0-9]{3}$ && "$s" != "A-000" ]] || { echo "FAIL: cluster $C has no Session tag of a BUDGET entry (got '$s')" >&2; exit 1; }
kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    platform.michelecampi.dev/session: "$s"
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
echo "session label: $s"
