# Cost allocation tags, activated once for the account and kept active: they
# live here, outside the cluster stack, because deleting
# aws_ce_cost_allocation_tag sets the tag Inactive, and the cluster stack is
# destroyed after every session (until 2026-11-23 it deactivated Project at
# every destroy).
#  - Project: the AWS Budget filter (modules/budget) and grouping per project.
#  - Session: the BUDGET entry of each live session (A-NNN), from
#    providers.tf and the Karpenter nodes; groups the cost per session.
# AWS accepts a key only after it has seen it on a resource (up to 24 h after
# the first session that carries it): before that, the apply fails on
# Session with "tag key not found" and must be run again later. Activation
# applies from then on; earlier months need a backfill
# (docs/runbooks/cost-allocation.md). Both cost nothing.
variable "cost_allocation_tags" {
  description = "Tag keys to keep active as cost allocation tags."
  type        = set(string)
  default     = ["Project", "Session"]
}

resource "aws_ce_cost_allocation_tag" "this" {
  for_each = var.cost_allocation_tags
  tag_key  = each.value
  status   = "Active"
}
