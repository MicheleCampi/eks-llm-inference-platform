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

variable "oncall_email" {
  description = "Address of platform-oncall-email, which receives severity page."
  type        = string
  sensitive   = true
}

# platform-oncall-email was created by hand for vllm-coldstart-operator
# (its hack/gpu-session/gke-l4/CHECKLIST.md: severity page goes there). It is
# imported by name, not recreated, so the shared stack has one owner as code.
import {
  to = grafana_contact_point.oncall
  id = "platform-oncall-email"
}

resource "grafana_contact_point" "oncall" {
  name = "platform-oncall-email"
  email {
    addresses    = [var.oncall_email]
    single_email = false
  }
}

# The Grafana Cloud stack is shared with vllm-coldstart-operator. A
# notification policy replaces the whole tree, so this repository is its only
# owner: route by severity, the label every rule of both projects carries.
# page -> platform-oncall-email; everything else -> platform-email.
resource "grafana_notification_policy" "this" {
  contact_point = grafana_contact_point.email.name
  group_by      = ["alertname", "nodepool"]

  policy {
    matcher {
      label = "severity"
      match = "="
      value = "page"
    }
    contact_point = grafana_contact_point.oncall.name
  }
}
