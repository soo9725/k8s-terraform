# 04-ingress/helm.tf

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = var.alb_controller_chart_repo
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  
  # [변경] 전용 네임스페이스 지정
  namespace        = "ingress-system"
  # [추가] 해당 네임스페이스가 없으면 생성하라 (필수!)
  create_namespace = true

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.cluster.outputs.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = data.aws_eks_cluster.main.vpc_config[0].vpc_id
  }
  
  # [추가] ALB Controller는 매우 중요하므로 On-Demand 사용
  set {
    name  = "nodeSelector.karpenter\\.sh/capacity-type"
    value = "on-demand"
  }
}