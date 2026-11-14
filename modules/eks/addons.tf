# metrics-server: resource metrics for kubectl top and the HorizontalPodAutoscaler.
# HA is the add-on default (schema in ci/schemas/), declared here so a change of
# default cannot remove it silently: 2 replicas across zones and a PDB, so it
# survives a node removed by Karpenter consolidation. Requests are starting
# values, to be checked against usage measured live.
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "metrics-server"
  addon_version = "v0.9.1-eksbuild.1" # default for 1.36, describe-addon-versions 2026-11-14

  # Validated in CI against the AWS schema (ci/addon-config.py).
  configuration_values = file("${path.module}/addons/metrics-server.json")

  depends_on = [aws_eks_node_group.default]
}

# VPC CNI managed and pinned, with network policy enforcement on: without it a
# NetworkPolicy is accepted by the API and enforced by nothing. OVERWRITE adopts
# the aws-node DaemonSet that EKS installs at cluster creation.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.22.4-eksbuild.14" # default for 1.36, describe-addon-versions 2026-11-14
  resolve_conflicts_on_create = "OVERWRITE"
  configuration_values        = file("${path.module}/addons/vpc-cni.json")
}
