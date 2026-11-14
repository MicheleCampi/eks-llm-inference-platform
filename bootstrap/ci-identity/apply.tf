# Apply and destroy from the protected GitHub environment "live" (workflows
# apply.yml, destroy.yml), and the permissions boundary every role the
# cluster stack creates must carry.
data "aws_caller_identity" "current" {}

locals {
  account        = data.aws_caller_identity.current.account_id
  partition      = data.aws_partition.current.partition
  apply_subject  = "repo:MicheleCampi@215741962/eks-llm-inference-platform@1299498076:environment:live"
  boundary_arn   = "arn:${local.partition}:iam::${local.account}:policy/eks-llm-boundary"
  stack_roles    = "arn:${local.partition}:iam::${local.account}:role/llm-inference-*"
  stack_policies = "arn:${local.partition}:iam::${local.account}:policy/llm-inference-*"
  # The only IAM a stack role may use: Karpenter's instance profile actions
  # (ci/karpenter/cloudformation-v1.15.1.yaml) and passing the node role to EC2.
  karpenter_iam = [
    "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
    "iam:GetInstanceProfile", "iam:ListInstanceProfiles", "iam:RemoveRoleFromInstanceProfile",
    "iam:TagInstanceProfile",
  ]
}

# Allow-list ceiling: everything except IAM, Organizations and account, plus
# Karpenter's IAM. A new IAM action stays out by default.
resource "aws_iam_policy" "boundary" {
  name        = "eks-llm-boundary"
  description = "Permissions boundary for every role the EKS stack creates"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AllowAllButIam", Effect = "Allow", NotAction = ["iam:*", "organizations:*", "account:*"], Resource = "*" },
      { Sid = "AllowKarpenterInstanceProfiles", Effect = "Allow", Action = local.karpenter_iam, Resource = "*" },
      { Sid = "AllowPassNodeRoleToEc2", Effect = "Allow", Action = "iam:PassRole", Resource = local.stack_roles, Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } } },
      { Sid = "DenyStateBucket", Effect = "Deny", Action = "s3:*", Resource = ["arn:${local.partition}:s3:::${local.state_bucket}", "arn:${local.partition}:s3:::${local.state_bucket}/*"] },
    ]
  })
}

resource "aws_iam_role" "apply" {
  name                 = "eks-llm-ci-apply"
  description          = "GitHub Actions apply/destroy, environment live only"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.apply_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_iam" {
  name = "stack-iam-and-state"
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "CreateStackRolesOnlyWithBoundary", Effect = "Allow", Action = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"], Resource = local.stack_roles, Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary_arn } } },
      { Sid = "ManageStackRoles", Effect = "Allow", Action = ["iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"], Resource = local.stack_roles },
      { Sid = "ReadServiceLinkedRoles", Effect = "Allow", Action = "iam:GetRole", Resource = ["arn:${local.partition}:iam::${local.account}:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot", "arn:${local.partition}:iam::${local.account}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"] },
      { Sid = "ManageStackPolicies", Effect = "Allow", Action = ["iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"], Resource = local.stack_policies },
      { Sid = "ManageClusterOidcProvider", Effect = "Allow", Action = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider"], Resource = "arn:${local.partition}:iam::${local.account}:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/*" },
      { Sid = "PassStackRoles", Effect = "Allow", Action = "iam:PassRole", Resource = local.stack_roles, Condition = { StringEquals = { "iam:PassedToService" = ["eks.amazonaws.com", "ec2.amazonaws.com", "pods.eks.amazonaws.com"] } } },
      { Sid = "ListStateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:${local.partition}:s3:::${local.state_bucket}" },
      { Sid = "ReadWriteStackState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["arn:${local.partition}:s3:::${local.state_bucket}/${local.state_key}", "arn:${local.partition}:s3:::${local.state_bucket}/${local.state_key}.tflock"] },
      { Sid = "DenyOtherStateObjects", Effect = "Deny", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], NotResource = ["arn:${local.partition}:s3:::${local.state_bucket}/${local.state_key}", "arn:${local.partition}:s3:::${local.state_bucket}/${local.state_key}.tflock"] },
      { Sid = "DenyCiIdentityAndBoundary", Effect = "Deny", Action = "iam:*", Resource = ["arn:${local.partition}:iam::${local.account}:role/eks-llm-ci-*", local.boundary_arn, data.aws_iam_openid_connect_provider.github.arn] },
      { Sid = "DenyBoundaryRemoval", Effect = "Deny", Action = "iam:DeleteRolePermissionsBoundary", Resource = "*" },
      { Sid = "DenySecretValues", Effect = "Deny", Action = "secretsmanager:GetSecretValue", Resource = "*" },
    ]
  })
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
