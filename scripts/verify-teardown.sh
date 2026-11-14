#!/usr/bin/env bash
# After terraform destroy: prove nothing billable is left (A-016 list).
# Exit 0 only if every count is 0. Read-only calls; prints no account id.
set -uo pipefail
C="${1:-llm-inference}"; R="${AWS_REGION:-eu-west-1}"; P="eks-llm-inference-platform"
fail=0
chk() { # name, count
  if [ "$2" = "0" ]; then echo "OK   $1: 0"; else echo "LEFT $1: $2"; fail=1; fi
}
q() { aws --region "$R" --output text "$@" || echo "ERR"; }
chk "EKS cluster $C" "$(q eks list-clusters --query "length(clusters[?@=='$C'])")"
chk "EC2 karpenter.sh/nodepool (not terminated)" "$(q ec2 describe-instances --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=pending,running,stopping,stopped --query 'length(Reservations[].Instances[])')"
chk "EC2 Project=$P (not terminated)" "$(q ec2 describe-instances --filters Name=tag:Project,Values=$P Name=instance-state-name,Values=pending,running,stopping,stopped --query 'length(Reservations[].Instances[])')"
chk "NAT gateways in $R (pending/available)" "$(q ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'length(NatGateways)')"
chk "Elastic IPs in $R" "$(q ec2 describe-addresses --query 'length(Addresses)')"
chk "EBS volumes Project=$P" "$(q ec2 describe-volumes --filters Name=tag:Project,Values=$P --query 'length(Volumes)')"
chk "SQS queues prefix $C" "$(q sqs list-queues --queue-name-prefix "$C" --query 'length(QueueUrls || `[]`)')"
chk "Secrets $C/ (incl. planned deletion)" "$(q secretsmanager list-secrets --include-planned-deletion --filters Key=name,Values="$C/" --query 'length(SecretList)')"
[ "$fail" = 0 ] && echo "TEARDOWN CLEAN" || echo "TEARDOWN NOT CLEAN: fix the LEFT lines before closing the session"
exit "$fail"
