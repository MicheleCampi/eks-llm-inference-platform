#!/usr/bin/env bash
# Live #3 without AWS FIS (Free Plan accounts get SubscriptionRequiredException):
# send ONE "EC2 Spot Instance Interruption Warning", shaped exactly as
# EventBridge delivers it, to Karpenter's real interruption queue, for one
# running Spot node of pool "general". From there the path is the production
# one: SQS -> Karpenter interruption controller -> cordon, drain within the
# PDBs, replacement NodeClaim, old instance terminated by Karpenter. What it
# does NOT prove: that AWS itself emits the warning and reclaims the instance
# (FIS, modules/eks/chaos.tf, var.fis_enabled, does that on a paid account).
# Message model: aws/karpenter-provider-aws v1.15.1,
# pkg/controllers/interruption/messages/{types.go,spotinterruption/}.
#
# Usage: bash tests/live/spot-interruption.sh [cluster]   (admin credentials)
#        bash tests/live/spot-interruption.sh --print <instance-id>   (no AWS)
set -euo pipefail
R="${AWS_REGION:-eu-west-1}"

message() { # instance-id account region -> EventBridge event JSON
  local id; id=$(cat /proc/sys/kernel/random/uuid)
  printf '{"version":"0","id":"%s","detail-type":"EC2 Spot Instance Interruption Warning","source":"aws.ec2","account":"%s","time":"%s","region":"%s","resources":["arn:aws:ec2:%s:%s:instance/%s"],"detail":{"instance-id":"%s","instance-action":"terminate"}}\n' \
    "$id" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$3" "$2" "$1" "$1"
}

if [ "${1:-}" = "--print" ]; then
  message "${2:?instance id}" 123456789012 "$R"
  exit 0
fi

C="${1:-llm-inference}"
A=$(aws sts get-caller-identity --query Account --output text)
I=$(aws --region "$R" ec2 describe-instances \
  --filters Name=tag:karpenter.sh/nodepool,Values=general "Name=tag:eks:eks-cluster-name,Values=$C" \
  Name=instance-lifecycle,Values=spot Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId | [0]' --output text)
[ -n "$I" ] && [ "$I" != "None" ] || { echo "no running Spot node of pool general"; exit 1; }
Q=$(aws --region "$R" sqs get-queue-url --queue-name "$C" --query QueueUrl --output text)
aws --region "$R" sqs send-message --queue-url "$Q" --message-body "$(message "$I" "$A" "$R")" --query MessageId --output text >/dev/null
echo "interruption warning sent for $I"
kubectl get nodes -o custom-columns=NODE:.metadata.name,PROVIDER:.spec.providerID | grep -F "$I" || true
