#!/usr/bin/env bash
# After terraform destroy: prove nothing billable is left (A-016 list), and
# nothing that shows the destroy stopped half way (A-026: VPC, ENIs, cluster SG).
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
# Control-plane log group: stored logs are billed per GB-month, and a group
# left behind (or one EKS created itself) would never expire.
chk "CloudWatch log groups /aws/eks/$C/" "$(q logs describe-log-groups --log-group-name-prefix "/aws/eks/$C/" --query 'length(logGroups)')"
# Not billable, but they block the next apply and leave state inconsistent
# (live attempt 2: Karpenter's instance profile kept the node role alive).
chk "IAM roles $C*" "$(q iam list-roles --query "length(Roles[?starts_with(RoleName,'$C')])")"
chk "IAM instance profiles $C* (incl. Karpenter)" "$(q iam list-instance-profiles --query "length(InstanceProfiles[?starts_with(InstanceProfileName,'$C')])")"
# Not billable either, but a VPC left behind means the destroy did not finish
# (A-026: an orphan VPC CNI ENI and the EKS-created cluster security group
# kept a subnet alive; Terraform owns neither). Runbook live.md section 10.
chk "VPCs Project=$P" "$(q ec2 describe-vpcs --filters Name=tag:Project,Values=$P --query 'length(Vpcs)')"
chk "VPC CNI ENIs (description aws-K8S-*)" "$(q ec2 describe-network-interfaces --filters 'Name=description,Values=aws-K8S-*' --query 'length(NetworkInterfaces)')"
chk "Security groups eks-cluster-sg-$C-*" "$(q ec2 describe-security-groups --filters "Name=group-name,Values=eks-cluster-sg-$C-*" --query 'length(SecurityGroups)')"
# FIS: a running experiment is billed per action-minute; the template is free
# but belongs to the stack.
# On an account without FIS (AWS Free Plan: SubscriptionRequiredException)
# nothing FIS can exist, so that answer counts as 0; any other error is ERR.
fq() { local o; o=$(aws --region "$R" --output text "$@" 2>&1) && echo "$o" && return
  case "$o" in *SubscriptionRequiredException*) echo 0 ;; *) echo "$o" >&2; echo ERR ;; esac; }
chk "FIS experiments running or initiating" "$(fq fis list-experiments --query "length(experiments[?state.status=='running' || state.status=='initiating'])")"
chk "FIS templates tagged Project=$P" "$(fq fis list-experiment-templates --query "length(experimentTemplates[?tags.Project=='$P'])")"
[ "$fail" = 0 ] && echo "TEARDOWN CLEAN" || echo "TEARDOWN NOT CLEAN: fix the LEFT lines before closing the session"
exit "$fail"
