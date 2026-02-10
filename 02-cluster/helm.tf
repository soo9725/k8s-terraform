# 02-cluster/helm.tf

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

# 2. PV (Persistent Volume)
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

# 4. StorageClass
resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
}

# 5. Jenkins 설치 (HTTPS 적용)
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
  
  # [NEW] HTTPS 인증서 적용 및 포트 설정
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
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn"
    value = var.acm_certificate_arn # ACM 변수 사용
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/listen-ports"
    value = "[{\"HTTPS\":443}, {\"HTTP\":80}]"
  }
  set {
    name  = "controller.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ssl-redirect"
    value = "443"
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

# 6. ArgoCD 설치 (HTTPS 적용)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "9.4.0" # 사용자 검증 버전
  create_namespace = true

  values = [
    yamlencode({
      global = {
        domain = "argocd.${var.domain_name}"
      }
      server = {
        service = {
          type = "NodePort"
          nodePortHttps = 30031
        }
        ingress = {
          enabled = true
          ingressClassName = "alb"
          hosts = [
            "argocd.${var.domain_name}"
          ]
          paths = ["/"]
          pathType = "Prefix"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/group.name"       = "terraform-k8s"
            
            # [중요] SSL Offloading: 파드와는 HTTP로 통신
            "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
            
            # [NEW] HTTPS 인증서 적용
            "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}, {\"HTTP\":80}]"
            "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
            
            "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
            "alb.ingress.kubernetes.io/success-codes"    = "200"
          }
        }
      }
      # Insecure 모드 (SSL Offloading 필수)
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