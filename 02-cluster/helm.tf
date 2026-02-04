# helm.tf (Final Fix: Static Provisioning with Persistent Data)

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
# 동적이 아니라 "Layer 1에 있는 그거(Access Point) 내놔"라고 명시합니다.
resource "kubernetes_persistent_volume" "jenkins_pv" {
  metadata {
    name = "jenkins-pv"
  }
  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain" # PV 지워져도 EFS 데이터는 보존
    storage_class_name               = "efs-sc" # 아래 SC 이름과 일치

    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        # [핵심] EFS ID :: Access Point ID 형식을 지켜야 합니다.
        volume_handle = "${data.terraform_remote_state.network.outputs.efs_id}::${data.terraform_remote_state.network.outputs.efs_access_point_id}"
      }
    }
  }
}

# 3. PVC (Persistent Volume Claim)
# Jenkins는 이 요청서를 통해 위에서 만든 PV와 연결됩니다.
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
    # 특정 PV와 1:1로 매핑 (Static Binding)
    volume_name = kubernetes_persistent_volume.jenkins_pv.metadata[0].name
  }
}

# 4. StorageClass (껍데기)
# Static Provisioning이라도 SC는 정의되어 있어야 에러가 안 납니다.
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
  version    = "5.8.134" # [FIX] 버전 고정 (Verified)
  timeout    = 900

  # 우리가 만든 PVC 사용
  set {
    name  = "persistence.existingClaim"
    value = kubernetes_persistent_volume_claim.jenkins_pvc.metadata[0].name
  }

  set {
    name  = "controller.admin.password"
    value = "test1234" 
  }

  set {
    name  = "controller.serviceType"
    value = "NodePort"
  }
  
  set {
    name  = "controller.nodePort"
    value = "30030"
  }

  # Layer 1 Access Point에서 이미 권한(1000:1000)을 잡아줬으므로
  # 여기서는 1000번 유저로 실행만 하면 됩니다.
  set {
    name  = "controller.runAsUser"
    value = "1000"
  }
  set {
    name  = "controller.fsGroup"
    value = "1000"
  }
  # 초기화 컨테이너 비활성화 (이미 권한이 맞으므로 불필요)
  set {
    name  = "controller.initializePipes"
    value = "false"
  }

  depends_on = [
    kubernetes_persistent_volume_claim.jenkins_pvc,
    aws_eks_node_group.main
  ]
}

# 6. ArgoCD 설치 (HTTPS 복구됨)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "9.4.0" # [FIX] 버전 고정 (Verified)
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "NodePort"
  }

  set {
    name  = "server.service.nodePortHttps"
    value = "30031"
  }
  
  depends_on = [aws_eks_node_group.main]
}