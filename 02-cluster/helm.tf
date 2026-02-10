# helm.tf (Final Fix: Static Provisioning with Persistent Data & ArgoCD Global Domain Fix)

# 1. EFS CSI Driver (도구 설치)
resource "helm_release" "efs_csi_driver" {
  name       = "aws-efs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver/"
  chart      = "aws-efs-csi-driver"
  namespace  = "kube-system"
  version    = "3.0.3"

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }
  
  depends_on = [aws_eks_node_group.main]
}

# 2. PV (Persistent Volume) - 수동 연결
resource "kubernetes_persistent_volume" "jenkins_pv" {
  metadata {
    name = "jenkins-pv"
  }
  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "efs-sc"

    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = "${data.terraform_remote_state.network.outputs.efs_id}::${data.terraform_remote_state.network.outputs.efs_access_point_id}"
      }
    }
  }
}

# 3. PVC (Persistent Volume Claim)
resource "kubernetes_persistent_volume_claim" "jenkins_pvc" {
  metadata {
    name      = "jenkins-pvc"
    namespace = "default"
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "efs-sc"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
    volume_name = kubernetes_persistent_volume.jenkins_pv.metadata[0].name
  }
}

# 4. StorageClass (껍데기)
resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
}

# 5. Jenkins 설치
resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  namespace  = "default"
  version    = "5.8.134"
  timeout    = 900

  set {
    name  = "persistence.existingClaim"
    value = kubernetes_persistent_volume_claim.jenkins_pvc.metadata[0].name
  }
  set {
    name  = "controller.admin.password"
    value = "test1234" 
  }
  # Ingress 활성화
  set {
    name  = "controller.ingress.enabled"
    value = "true"
  }
  set {
    name  = "controller.ingress.ingressClassName"
    value = "alb"
  }
  set {
    name  = "controller.ingress.hostName"
    value = "jenkins.${var.domain_name}"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = "internet-facing"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
    value = "ip"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/group\\.name"
    value = "terraform-k8s"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/healthcheck-path"
    value = "/login"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/success-codes"
    value = "200-399"
  }
  set {
    name  = "controller.serviceType"
    value = "NodePort"
  }
  set {
    name  = "controller.nodePort"
    value = "30030"
  }
  set {
    name  = "controller.runAsUser"
    value = "1000"
  }
  set {
    name  = "controller.fsGroup"
    value = "1000"
  }
  set {
    name  = "controller.initializePipes"
    value = "false"
  }

  depends_on = [
    kubernetes_persistent_volume_claim.jenkins_pvc,
    aws_eks_node_group.main
  ]
}

# 6. ArgoCD 설치 (9.4.0 버전 + global.domain 추가)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "9.4.0" # [FIX] 사용자 검증 버전 유지
  create_namespace = true

  # [핵심 변경] values + yamlencode 사용
  values = [
    yamlencode({
      # 1. 전역 도메인 설정 (example.com 문제 해결의 핵심)
      global = {
        domain = "argocd.${var.domain_name}"
      }

      # 2. 서버 설정
      server = {
        service = {
          type = "NodePort"
          nodePortHttps = 30031
        }
        ingress = {
          enabled = true
          ingressClassName = "alb"
          # 리스트 형태로 명확하게 주입
          hosts = [
            "argocd.${var.domain_name}"
          ]
          paths = ["/"]
          pathType = "Prefix"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/group.name"       = "terraform-k8s"
            "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
            "alb.ingress.kubernetes.io/success-codes"    = "200"
            # [추가] SSL 리다이렉트 루프 방지
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
          }
        }
      }
      # 3. 설정 (SSL Termination을 ALB에서 하므로 내부는 insecure)
      configs = {
        params = {
          "server.insecure" = "true"
        }
      }
    })
  ]

  depends_on = [aws_eks_node_group.main]
}

# 7. ExternalDNS 설치
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = "1.14.3"

  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_dns.arn
  }
  set {
    name  = "provider"
    value = "aws"
  }
  set {
    name  = "policy"
    value = "sync"
  }
  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }
  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }
  
  depends_on = [aws_eks_node_group.main, aws_iam_role.external_dns]
}