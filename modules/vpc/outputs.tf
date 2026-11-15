output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_gateway_count" {
  value = local.nat_count
}

output "private_subnet_discovery_tags" {
  description = "Value of karpenter.sh/discovery on each private subnet (empty if missing)."
  value       = [for s in aws_subnet.private : lookup(s.tags, "karpenter.sh/discovery", "")]
}
