# The Project tag comes from local.tags (providers.tf), the same map as default_tags.
module "budget" {
  source            = "./modules/budget"
  name              = var.cluster_name
  project           = local.tags["Project"]
  monthly_limit_usd = var.budget_monthly_limit_usd
  alert_emails      = var.budget_alert_emails
}

# The activation moved to bootstrap/ci-identity (cost-allocation-tags.tf). A
# state that still holds it forgets it without deactivating the tag.
removed {
  from = module.budget.aws_ce_cost_allocation_tag.project
  lifecycle {
    destroy = false
  }
}
