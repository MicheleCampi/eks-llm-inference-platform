# The budget counts only spend tagged Project, alerts only when addresses are
# given, and rejects a malformed address.
mock_provider "aws" {}

variables {
  name              = "llm-inference"
  project           = "eks-llm-inference-platform"
  monthly_limit_usd = 5
  alert_emails      = ["ops@example.com"]
}

run "filtered_on_project_tag" {
  command = plan
  module {
    source = "./modules/budget"
  }
  assert {
    condition     = anytrue([for f in aws_budgets_budget.this.cost_filter : f.name == "TagKeyValue" && contains(f.values, "user:Project$eks-llm-inference-platform")])
    error_message = "budget must filter on user:Project$eks-llm-inference-platform"
  }
  assert {
    condition     = aws_budgets_budget.this.limit_amount == "5.00" && aws_budgets_budget.this.time_unit == "MONTHLY"
    error_message = "budget must be 5.00 USD per month"
  }
  assert {
    condition     = length(aws_budgets_budget.this.notification) == 2
    error_message = "two alerts expected: actual 80%, forecast 100%"
  }
  assert {
    condition     = aws_ce_cost_allocation_tag.project.tag_key == "Project" && aws_ce_cost_allocation_tag.project.status == "Active"
    error_message = "Project must be an active cost allocation tag"
  }
}

run "no_emails_no_alerts" {
  command = plan
  module {
    source = "./modules/budget"
  }
  variables {
    alert_emails = []
  }
  assert {
    condition     = length(aws_budgets_budget.this.notification) == 0
    error_message = "no alerts without addresses"
  }
}

run "rejects_bad_email" {
  command = plan
  module {
    source = "./modules/budget"
  }
  variables {
    alert_emails = ["not-an-email"]
  }
  expect_failures = [var.alert_emails]
}
