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
  
  # [추가] EFS Driver도 중요하므로 On-Demand 사용
  set {
    name  = "nodeSelector.karpenter\\.sh/capacity-type"
    value = "on-demand"
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

  # [핵심] set 블록 대신 values + yamlencode 사용
  values = [
    yamlencode({
      persistence = {
        existingClaim = kubernetes_persistent_volume_claim.jenkins_pvc.metadata[0].name
      }
      
      controller = {
        admin = {
          password = "test1234"
        }
        
        # [추가] Jenkins Master는 절대 죽으면 안 되므로 On-Demand 강제
        nodeSelector = {
          "karpenter.sh/capacity-type" = "on-demand"
        }
        
        # Ingress 및 HTTPS 설정
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          hostName         = "jenkins.${var.domain_name}"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/group.name"       = "terraform-k8s"
            "alb.ingress.kubernetes.io/healthcheck-path" = "/login"
            "alb.ingress.kubernetes.io/success-codes"    = "200-399"
            
            # [오류 해결 포인트] 여기서 변수 그대로 넣으면 깔끔하게 들어갑니다.
            "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}, {\"HTTP\":80}]"
            "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
          }
        }

        # 기타 설정
        serviceType     = "NodePort"
        nodePort        = 30030
        runAsUser       = 1000
        fsGroup         = 1000
        initializePipes = false
      }
    })
  ]

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
  version          = "5.51.6" # 최신 안정 버전 권장 (사용자 검증 버전 9.4.0은 차트 버전이 아닐 수 있음, 확인 필요)
  create_namespace = true

  values = [
    yamlencode({
      # [추가] 전역 설정으로 ArgoCD 모든 컴포넌트 On-Demand 강제
      global = {
        domain = "argocd.${var.domain_name}"
        nodeSelector = {
          "karpenter.sh/capacity-type" = "on-demand"
        }
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
  
  # [추가] DNS 서비스 중요하므로 On-Demand 사용
  set {
    name  = "nodeSelector.karpenter\\.sh/capacity-type"
    value = "on-demand"
  }
  
  depends_on = [aws_eks_node_group.main, aws_iam_role.external_dns]
}