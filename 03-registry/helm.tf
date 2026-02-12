# 03-registry/helm.tf

# -------------------------------------------------------------
# 1. Namespace 생성
# -------------------------------------------------------------
resource "kubernetes_namespace" "harbor" {
  metadata {
    name = "harbor"
  }
}

# -------------------------------------------------------------
# 2. Default ServiceAccount에 신분증(IAM) 강제 부착
# -------------------------------------------------------------
resource "kubernetes_default_service_account" "harbor_default" {
  metadata {
    namespace = kubernetes_namespace.harbor.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.harbor.arn
    }
  }
  automount_service_account_token = true
}

# -------------------------------------------------------------
# 3. Harbor 설치 (HTTPS 적용)
# -------------------------------------------------------------
resource "helm_release" "harbor" {
  name             = "harbor"
  repository       = "https://helm.goharbor.io"
  chart            = "harbor"
  version          = "1.18.2"
  
  namespace        = kubernetes_namespace.harbor.metadata[0].name
  create_namespace = false
  timeout          = 900

  values = [
    yamlencode({
      # 1. 전역 설정
      serviceAccount = {
        create = false
        name   = "default" 
      }

      # [추가] 중요 데이터 보호를 위해 모든 컴포넌트 On-Demand 강제
      
      # 2. Registry 컴포넌트
      registry = {
        replicas = 1
        serviceAccount = {
          create = false
          name   = "default"
        }
        serviceAccountName = "default"
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }

      # 3. 기타 컴포넌트 강제 지정
      core       = { 
        serviceAccount = { create = false, name = "default" }
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      jobservice = { 
        serviceAccount = { create = false, name = "default" }
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      portal     = { 
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      # DB와 Redis는 특히 중요하므로 필수
      database   = { 
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      redis      = { 
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      
      trivy      = { 
        enabled = false 
        # (Enable 할 경우를 대비해 미리 추가)
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      notary     = { enabled = false }

      # 4. 외부 접속 및 기타 설정
      expose = {
        type = "ingress"
        # Harbor 자체 TLS는 끄고 ALB에 맡김 (SSL Offloading)
        tls = { enabled = false } 
        
        ingress = {
          hosts = {
            core = "harbor.${var.domain_name}"
          }
          controller = "alb"
          className  = "alb"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/group.name"       = "terraform-k8s"
            
            # [NEW] HTTPS 인증서 적용 (핵심)
            "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn
            
            # [NEW] HTTPS(443) 포트 열기 및 SSL 리다이렉트
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}, {\"HTTP\":80}]"
            "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
            
            "alb.ingress.kubernetes.io/healthcheck-path" = "/api/v2.0/ping"
            "alb.ingress.kubernetes.io/success-codes"    = "200"
          }
        }
      }

      # [NEW] 외부 접속 URL (HTTPS로 변경)
      externalURL = "https://harbor.${var.domain_name}"
      
      harborAdminPassword = "Harbor1234!"

      # 5. 스토리지 (S3 + EBS)
      persistence = {
        imageChartStorage = {
          type = "s3"
          s3 = {
            region = var.region
            bucket = data.terraform_remote_state.network.outputs.s3_bucket_name
          }
        }
        persistentVolumeClaim = {
          database   = { storageClass = "gp2", accessMode = "ReadWriteOnce" }
          redis      = { storageClass = "gp2", accessMode = "ReadWriteOnce" }
          jobservice = { 
            storageClass = "gp2", accessMode = "ReadWriteOnce", size = "1Gi"
            jobLog = { storageClass = "gp2", accessMode = "ReadWriteOnce", size = "1Gi" }
          }
        }
      }

      # 6. 기타 설정
      portal     = { replicas = 1 }
    })
  ]
  
  depends_on = [kubernetes_default_service_account.harbor_default]
}