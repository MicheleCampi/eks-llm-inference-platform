variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "llm-inference"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC."
  type        = string
  default     = "10.42.0.0/16"
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
