# The Project tag comes from local.tags (providers.tf), the same map as default_tags.
module "budget" {
  source            = "./modules/budget"
  name              = var.cluster_name
  project           = local.tags["Project"]
  monthly_limit_usd = var.budget_monthly_limit_usd
  alert_emails      = var.budget_alert_emails
}
