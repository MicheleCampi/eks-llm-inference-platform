# Grafana Cloud remote-write credentials for Alloy, read by External Secrets
# Operator through EKS Pod Identity bound to exactly one service account:
# external-secrets/external-secrets. Terraform creates the secret empty; the
# value (JSON: url, user, token) is put at live time, so it is never in state.
resource "aws_secretsmanager_secret" "grafana_cloud" {
  name                    = "${var.cluster_name}/grafana-cloud-remote-write"
  description             = "Grafana Cloud remote write (url, user, token). Value set out of band."
  recovery_window_in_days = 0
}

resource "aws_iam_role" "eso" {
  name = "${var.cluster_name}-eso"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
    }]
  })
}

# Read-only, and only this secret.
resource "aws_iam_role_policy" "eso" {
  name = "read-grafana-cloud-secret"
  role = aws_iam_role.eso.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.grafana_cloud.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}
