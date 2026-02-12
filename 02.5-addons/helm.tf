# 02.5-addons/helm.tf

# -------------------------------------------------------------
# 1. Metrics Server (On-Demand 강제)
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
      nodeSelector = {
        "karpenter.sh/capacity-type" = "on-demand"
      }
    })
  ]
}

# -------------------------------------------------------------
# 2. Karpenter 설치 (v0.32.1 버전 수정)
# -------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  # [Best Practice] OCI 레지스트리 직접 참조
  chart            = "oci://public.ecr.aws/karpenter/karpenter"
  # [핵심 수정] 0.32.1 -> v0.32.1 (v 접두사 필수)
  version          = "v0.32.1"
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
      # v0.32.x 버전의 올바른 nodeSelector 설정 경로
      controller = {
        nodeSelector = {
          "karpenter.sh/capacity-type" = "on-demand"
        }
      }
    })
  ]
}

# -------------------------------------------------------------
# 3. KEDA Operator 설치 (On-Demand 강제)
# -------------------------------------------------------------
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  version          = "2.12.0"
  create_namespace = true

  values = [
    yamlencode({
      # KEDA의 모든 컴포넌트가 On-Demand 노드에만 뜨도록 설정
      nodeSelector = {
        "karpenter.sh/capacity-type" = "on-demand"
      }
      operator = {
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      metricsServer = {
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
    })
  ]
}

# -------------------------------------------------------------
# 4. EC2NodeClass (AWS 인프라 연결)
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
        # 01-network에서 정의한 Private 서브넷 태그와 일치해야 함
        Name: "${var.project_name}-private-*"
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
# 5. NodePool (Spot 우선, On-Demand 허용)
# -------------------------------------------------------------
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<YAML
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "t"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
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