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
# 2. [핵심 변경] Default ServiceAccount에 신분증(IAM) 강제 부착
# -------------------------------------------------------------
# Harbor가 자꾸 default를 쓰니까, 아예 default에 권한을 줘버립니다.
resource "kubernetes_default_service_account" "harbor_default" {
  metadata {
    namespace = kubernetes_namespace.harbor.metadata[0].name
    # "default"라는 이름은 생략 가능(기본값)하지만 명시적으로 지정
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.harbor.arn
    }
  }
  
  # 기존 default SA를 덮어쓰기 위해 설정
  automount_service_account_token = true
}

# -------------------------------------------------------------
# 3. Harbor 설치 (Default SA 사용)
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
      # 1. 전역 설정: SA 만들지 말고 default 써라
      serviceAccount = {
        create = false
        name   = "default" 
      }

      # 2. Registry 컴포넌트: 혹시 모르니 여기도 default 명시 (양쪽 문법 다 커버)
      registry = {
        replicas = 1
        serviceAccount = {
          create = false
          name   = "default"
        }
        # 구버전/신버전 문법 호환성 확보를 위해 추가
        serviceAccountName = "default"
      }

      # 3. 기타 컴포넌트 강제 지정
      core       = { serviceAccount = { create = false, name = "default" } }
      jobservice = { serviceAccount = { create = false, name = "default" } }

      # 4. 외부 접속 및 기타 설정 (기존과 동일)
      expose = {
        type = "nodePort"
        tls = {
          nodePort = 30003
          auto = { commonName = "localhost" }
        }
        http = { nodePort = 30002 }
      }
      externalURL = "https://localhost:30003"
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
      trivy      = { enabled = false }
      notary     = { enabled = false }
    })
  ]
  
  # SA에 권한 부여가 끝난 뒤 Helm 실행
  depends_on = [kubernetes_default_service_account.harbor_default]
}