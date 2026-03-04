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
  chart            = "oci://public.ecr.aws/karpenter/karpenter"
  version          = "0.35.1"
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
# 4. EC2NodeClass (AWS 인프라 연결) - [핵심 수정 구간]
# -------------------------------------------------------------
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  instanceProfile: "${aws_iam_instance_profile.karpenter_node.name}"
  subnetSelectorTerms:
    - tags:
        Name: "terraform-k8s-private-*"
  
  # [수정됨] 노드 간 통신을 위한 보안 그룹을 확실히 찾도록 OR 조건(리스트 항목 추가) 부여
  securityGroupSelectorTerms:
    - tags:
        "kubernetes.io/cluster/${var.cluster_name}": "owned"
    - tags:
        "karpenter.sh/discovery": "${var.cluster_name}"

  tags:
    Name: karpenter-node
    CreatedBy: karpenter
YAML

  depends_on = [helm_release.karpenter]
}

# -------------------------------------------------------------
# 5. NodePool (최소 사양 및 amd64 고정)
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
          values: ["c", "m", "t", "r"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
        - key: "karpenter.k8s.aws/instance-generation"
          operator: Gt
          values: ["2"]
      nodeClassRef:
        name: default
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 1h
YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}