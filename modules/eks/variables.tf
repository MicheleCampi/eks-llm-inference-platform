variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster (pin to stay in standard support)."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for control plane ENIs, managed nodes and Karpenter nodes."
  type        = list(string)
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. No default: set at apply time with TF_VAR_public_access_cidrs, never committed."
  type        = list(string)
  validation {
    condition     = length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "public_access_cidrs must be non-empty and must not contain 0.0.0.0/0 (EKS treats an empty list as open to the internet)."
  }
}

variable "irsa_roles" {
  description = "IAM roles for service accounts: key = role suffix; each bound to exactly one namespace and service account."
  type = map(object({
    namespace       = string
    service_account = string
    policy_arns     = list(string)
  }))
  default = {}
  validation {
    condition = alltrue([for r in values(var.irsa_roles) :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", r.namespace)) &&
    can(regex("^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$", r.service_account))])
    error_message = "irsa_roles: namespace and service_account must be exact Kubernetes names; wildcards are rejected."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every IAM role of this module carries (eks-llm-boundary, bootstrap/ci-identity)."
  type        = string
}

variable "cluster_admin_principal_arns" {
  description = "IAM user or role ARNs granted AmazonEKSClusterAdminPolicy (cluster scope) through access entries. No wildcards."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.cluster_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", a))])
    error_message = "cluster_admin_principal_arns must be IAM user or role ARNs, without wildcards."
  }
}

variable "fis_enabled" {
  description = "Create the AWS FIS Spot interruption template and its role (chaos.tf). Off by default: AWS Free Plan accounts get SubscriptionRequiredException from FIS, so creating the template fails the apply. Turn on for an account with FIS access."
  type        = bool
  default     = false
}
