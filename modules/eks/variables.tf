variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster (pin to stay in standard support)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for control plane ENIs and nodes."
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
