#!/usr/bin/env bash
# Pre-flight for a live session (docs/runbooks/live.md, step 0): simulate, on the
# real eks-llm-ci-apply role, every IAM action the stack's apply and destroy need
# and the ones it must never get. Live attempt 1 (2026-11-14) failed on IAM gaps
# that only a real apply found. IAM actions come from CloudTrail of that attempt
# plus what it never reached (destroy, PassRole, which CloudTrail does not log).
# Usage: bash ci/simulate-apply-role.sh   (administrator credentials, read-only)
set -euo pipefail
cd "$(dirname "$0")/.."
A=$(aws sts get-caller-identity --query Account --output text)
P=arn:aws:iam::$A
ROLE=$P:role/eks-llm-ci-apply
BOUNDARY=$P:policy/eks-llm-boundary
BUCKET=michele-tfstate-eks-llm
KEY=$(grep -hoE '^\s*key\s*=\s*"[^"]+"' *.tf | head -1 | cut -d'"' -f2)
[ -n "$KEY" ] || { echo "state key not found"; exit 1; }
R=$P:role/llm-inference-sim
POL=$P:policy/llm-inference-sim
OIDC=$P:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/SIM
SLR_NG=$P:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup
SLR_SPOT=$P:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot
fail=0
sim() { # expected action resource [context-key context-value]
  local want=$1 act=$2 res=$3 ctx=()
  [ $# -ge 5 ] && ctx=(--context-entries "ContextKeyName=$4,ContextKeyValues=$5,ContextKeyType=string")
  got=$(aws iam simulate-principal-policy --policy-source-arn "$ROLE" --action-names "$act" --resource-arns "$res" "${ctx[@]}" --query 'EvaluationResults[0].EvalDecision' --output text)
  case "$want:$got" in allowed:allowed|denied:implicitDeny|denied:explicitDeny) r=PASS ;; *) r=FAIL; fail=1 ;; esac
  printf '%s  %-8s %-14s %-36s %s %s\n' "$r" "$want" "$got" "$act" "${res##*:}" "${4:+[$4=${5##*/}]}"
}
# Stack roles: create only with the boundary, then manage and delete.
sim allowed iam:CreateRole "$R" iam:PermissionsBoundary "$BOUNDARY"
sim denied  iam:CreateRole "$R"
for a in GetRole TagRole UntagRole GetRolePolicy DeleteRolePolicy ListRolePolicies ListAttachedRolePolicies DetachRolePolicy ListInstanceProfilesForRole UpdateAssumeRolePolicy DeleteRole; do sim allowed iam:$a "$R"; done
sim allowed iam:AttachRolePolicy "$R" iam:PermissionsBoundary "$BOUNDARY"
# Inline policies only on roles that carry the boundary.
sim allowed iam:PutRolePolicy "$R" iam:PermissionsBoundary "$BOUNDARY"
sim denied  iam:PutRolePolicy "$R"
# Stack policies.
for a in CreatePolicy GetPolicy GetPolicyVersion ListPolicyVersions CreatePolicyVersion DeletePolicyVersion TagPolicy DeletePolicy; do sim allowed iam:$a "$POL"; done
# Cluster OIDC provider.
for a in CreateOpenIDConnectProvider GetOpenIDConnectProvider TagOpenIDConnectProvider DeleteOpenIDConnectProvider; do sim allowed iam:$a "$OIDC"; done
# PassRole: not in CloudTrail; only to the three services the stack uses.
for s in eks.amazonaws.com ec2.amazonaws.com pods.eks.amazonaws.com; do sim allowed iam:PassRole "$R" iam:PassedToService "$s"; done
sim denied  iam:PassRole "$R" iam:PassedToService lambda.amazonaws.com
# Service-linked roles: read only (attempt 1).
sim allowed iam:GetRole "$SLR_NG"
sim allowed iam:GetRole "$SLR_SPOT"
sim denied  iam:TagRole "$SLR_SPOT"
sim denied  iam:DeleteRole "$SLR_SPOT"
# State: its own key and lock only.
sim allowed s3:GetObject "arn:aws:s3:::$BUCKET/$KEY"
sim allowed s3:PutObject "arn:aws:s3:::$BUCKET/$KEY.tflock"
sim denied  s3:GetObject "arn:aws:s3:::$BUCKET/eks-llm-inference-platform/grafana.tfstate"
# Never: CI identity, boundary, users, secret values.
sim denied  iam:UpdateAssumeRolePolicy "$P:role/eks-llm-ci-apply"
sim denied  iam:CreatePolicyVersion "$BOUNDARY"
sim denied  iam:DeleteRolePermissionsBoundary "$R"
sim denied  iam:CreateUser "$P:user/sim"
sim denied  secretsmanager:GetSecretValue "arn:aws:secretsmanager:eu-west-1:$A:secret:llm-inference/sim"
[ $fail -eq 0 ] && echo "PREFLIGHT PASS" || { echo "PREFLIGHT FAIL"; exit 1; }
