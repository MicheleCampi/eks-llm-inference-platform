# Monthly cost budget for this project: no actions and no reports, so AWS
# Budgets charges nothing for it. It counts only spend tagged Project=<project>
# (Terraform default_tags, Karpenter EC2NodeClass and node launch template).

variable "name" {
  type = string
}

variable "project" {
  description = "Value of the Project cost allocation tag."
  type        = string
}

variable "monthly_limit_usd" {
  type = number
  validation {
    condition     = var.monthly_limit_usd > 0 && var.monthly_limit_usd <= 50
    error_message = "monthly_limit_usd must be between 0 and 50."
  }
}

variable "alert_emails" {
  description = "Addresses for the alerts. Empty: budget without alerts."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "every alert_emails entry must be an email address."
  }
}

# Without activation the TagKeyValue filter matches nothing.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_budgets_budget" "this" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project)]
  }

  # Actual spend past 80%, forecast past 100%.
  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? { ACTUAL = 80, FORECASTED = 100 } : {}
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.key
      subscriber_email_addresses = var.alert_emails
    }
  }

  depends_on = [aws_ce_cost_allocation_tag.project]
}

output "budget_name" {
  value = aws_budgets_budget.this.name
}
