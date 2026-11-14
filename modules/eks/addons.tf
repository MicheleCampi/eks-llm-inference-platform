# metrics-server: resource metrics for kubectl top and the HorizontalPodAutoscaler.
# HA is the add-on default (schema in ci/schemas/), declared here so a change of
# default cannot remove it silently: 2 replicas across zones and a PDB, so it
# survives a node removed by Karpenter consolidation. Requests are starting
# values, to be checked against usage measured live.
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "metrics-server"
  addon_version = "v0.9.1-eksbuild.1" # default for 1.36, describe-addon-versions 2026-11-14

  configuration_values = jsonencode({
    replicas            = 2
    podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "topology.kubernetes.io/zone"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector     = { matchLabels = { "app.kubernetes.io/name" = "metrics-server", "app.kubernetes.io/instance" = "metrics-server" } }
    }]
    resources = { requests = { cpu = "100m", memory = "200Mi" } }
  })

  depends_on = [aws_eks_node_group.default]
}
