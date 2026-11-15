variable "name" {
  description = "Prefix for VPC resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "nat_mode" {
  type        = string
  default     = "single"
  description = "none = no egress, single = one shared NAT (test/dev), per_az = one NAT per AZ (production HA)."
  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_mode)
    error_message = "nat_mode must be none, single or per_az."
  }
}

variable "private_subnet_tags" {
  description = "Extra tags on the private subnets (e.g. karpenter.sh/discovery). Owned here only: no aws_ec2_tag on the same key."
  type        = map(string)
  default     = {}
}
