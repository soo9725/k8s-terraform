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
# 2. Karpenter 설치 (On-Demand 강제)
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
# [답변 3] KEDA "설치"는 여기서 하는 게 맞습니다. (시스템 도구니까요)
# 나중에 Layer 5에서 쓰는 건 "설정 파일(ScaledObject)"입니다.
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  version          = "2.12.0"
  create_namespace = true

  values = [
    yamlencode({
      nodeSelector = {
        "karpenter.sh/capacity-type" = "on-demand"
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
        # [주의] 01-network 변수명과 일치하는지 확인하세요
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
        # [핵심] Spot을 리스트 앞쪽에 두어 우선순위 부여
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"]
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