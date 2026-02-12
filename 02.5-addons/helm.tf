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
      # [핵심] Metrics Server는 중요하므로 On-Demand 사용
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
      # Karpenter 컨트롤러 자체도 끊기면 안 되므로 On-Demand 사용
      nodeSelector = {
        "karpenter.sh/capacity-type" = "on-demand"
      }
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
        # 01-network에서 설정한 태그와 일치하는지 꼭 확인하세요!
        # 만약 karpenter.sh/discovery 태그가 없다면 Name 태그 사용
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
# 4. NodePool: Default (Spot 우선, 하지만 On-Demand도 가능)
# -------------------------------------------------------------
resource "kubectl_manifest" "karpenter_nodepool_default" {
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
        # [핵심] Spot을 리스트의 앞에 둠으로써 우선순위를 부여
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

# -------------------------------------------------------------
# 5. KEDA 설치 (On-Demand 강제)
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
      # KEDA Operator도 중요하므로 On-Demand 사용
      nodeSelector = {
        "karpenter.sh/capacity-type" = "on-demand"
      }
    })
  ]
}