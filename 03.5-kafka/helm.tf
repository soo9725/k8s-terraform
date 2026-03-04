# 03.5-middleware/helm.tf

# -------------------------------------------------------------
# 1. Strimzi Kafka Operator 설치
# -------------------------------------------------------------
resource "helm_release" "strimzi_operator" {
  name             = "strimzi-operator"
  repository       = "https://strimzi.io/charts/"
  chart            = "strimzi-kafka-operator"
  namespace        = "kafka"
  create_namespace = true
  
  # [중요] K8s 1.30 지원 안정 버전 (2024년 기준)
  version          = "0.43.0"

  # 오퍼레이터는 중요하므로 On-Demand 노드에 배치 (안정성)
  set {
    name  = "nodeSelector.karpenter\\.sh/capacity-type"
    value = "on-demand"
  }
}
