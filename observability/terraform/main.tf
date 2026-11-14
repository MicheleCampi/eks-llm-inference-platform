# Grafana Cloud as code: dashboards, the email contact point and the
# notification policy. Alert rules are not here: the Prometheus-format
# observability/karpenter-rules.yaml, tested by promtool, is the only source and
# is loaded with mimirtool rules sync (Grafana /api/convert/). Credentials come
# from GRAFANA_URL and GRAFANA_AUTH in the environment, never from files.
terraform {
  required_version = ">= 1.15.0"
  required_providers {
    grafana = { source = "grafana/grafana", version = "= 4.55.0" }
  }
  backend "s3" {
    bucket       = "michele-tfstate-eks-llm"
    key          = "eks-llm-inference-platform/grafana.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}

provider "grafana" {}

variable "alert_email" {
  description = "Address the alert emails go to."
  type        = string
  sensitive   = true
}

resource "grafana_folder" "platform" {
  title = "eks-llm-inference-platform"
  uid   = "eks-llm-inference-platform"
}

resource "grafana_dashboard" "this" {
  for_each    = toset(["karpenter-dashboard.json", "rightsizing-dashboard.json"])
  folder      = grafana_folder.platform.uid
  config_json = file("${path.module}/../${each.key}")
}

resource "grafana_contact_point" "email" {
  name = "platform-email"
  email {
    addresses = [var.alert_email]
  }
}

# Replaces the whole policy tree: acceptable only because the Grafana Cloud
# stack is dedicated to this project (README, Production gaps).
resource "grafana_notification_policy" "this" {
  contact_point = grafana_contact_point.email.name
  group_by      = ["alertname", "nodepool"]
}
