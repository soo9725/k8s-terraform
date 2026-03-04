# -------------------------------------------------------------
# 1. AWS Account ID 조회 (IAM 설정용)
# -------------------------------------------------------------
data "aws_caller_identity" "current" {}

# [삭제됨] provider "aws" 설정은 provider.tf로 이동했습니다. (중복 방지)

# -------------------------------------------------------------
# 2. Remote State (Layer 1, Layer 2 정보 가져오기)
# -------------------------------------------------------------
# Layer 1: Network & Storage (S3 버킷 이름 필요)
data "terraform_remote_state" "network" {
  backend = "s3" 
  config = {
    bucket = "terraform-k8s-tfstate" 
    key    = "01-network/terraform.tfstate" 
    region = "ap-northeast-1"
  }
}

# Layer 2: Cluster (EKS 접속 정보 및 OIDC 필요)
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "terraform-k8s-tfstate" # 1번에서 만든 버킷 이름
    key    = "02-cluster/terraform.tfstate" # 참조하려는 대상 레이어의 key 경로
    region = "ap-northeast-1"
  }
}
# [삭제됨] provider "helm" 설정은 provider.tf로 이동했습니다. (중복 방지)