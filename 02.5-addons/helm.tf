# 02.5-addons/helm.tf

# -------------------------------------------------------------
# 1. Metrics Server (기존 노드 활용)
# -------------------------------------------------------------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.11.0"

  values = [
    yamlencode({
      args = ["--kubelet-insecure-tls"]
      # [변경] 특정 풀이 아니라 'On-Demand' 능력만 요구함
      # 기존 Terraform 노드(On-Demand)에도 배치될 수 있음
      #nodeSelector = {
        #"karpenter.sh/capacity-type" = "on-demand" 
      #}
      # 만약 기존 노드에 라벨이 없다면 nodeSelector를 아예 빼도 됩니다.
      # (기존 노드가 꽉 차면 Karpenter가 알아서 확장함)
    })
  ]
}

# -------------------------------------------------------------
# 2. Karpenter 설치
# -------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "0.32.1"
  namespace        = "karpenter"
  create_namespace = true

  values = [
    yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter_irsa.iam_role_arn
        }
      }
      settings = {
        clusterName = var.cluster_name
      }
      # Karpenter 자체도 기존 노드에 뜨게 둠 (Selector 제거)
    })
  ]
}

# -------------------------------------------------------------
# 3. Karpenter NodeClass (공용)
# -------------------------------------------------------------
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: "${aws_iam_role.karpenter_node.name}"
  subnetSelectorTerms:
    - tags:
        Name: "${var.project_name}-private-*" # [확인] 01-network 태그와 일치해야 함
  securityGroupSelectorTerms:
    - tags:
        "aws:eks:cluster-name": "${var.cluster_name}"
  tags:
    Name: karpenter-node
    CreatedBy: karpenter
YAML

  depends_on = [helm_release.karpenter]
}

# -------------------------------------------------------------
# 4. [통합] NodePool: Default (앱 & 시스템 확장용)
# -------------------------------------------------------------
resource "kubectl_manifest" "karpenter_nodepool_default" {
  yaml_body = <<YAML
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        tier: app # 기본적으로 앱용으로 사용
    spec:
      requirements:
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "t"] 
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"] # 스팟 우선 (비용 절감)
      nodeClassRef:
        name: default
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# -------------------------------------------------------------
# 5. KEDA 설치
# -------------------------------------------------------------
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  version          = "2.12.0"
  create_namespace = true
}