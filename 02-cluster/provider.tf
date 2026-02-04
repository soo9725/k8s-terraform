# provider.tf
# AWS, Kubernetes, Helm, TLS 프로바이더 설정 및 인증 처리

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # [NEW] EKS 제어를 위한 Kubernetes 프로바이더
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    # [NEW] 앱 설치를 위한 Helm 프로바이더
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    # OIDC 인증서 지문 계산용
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  # [Best Practice] 모든 리소스에 자동으로 붙는 태그
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"
      ManagedBy   = "Terraform"
      Layer       = "02-cluster"
    }
  }
}

# ----------------------------------------------------------------
# Kubernetes & Helm Provider 설정
# ----------------------------------------------------------------
# 중요: 클러스터를 생성하는 동시에 Provider를 설정할 때는 'data' 소스를 쓰면 안 됩니다.
# (아직 생성되지 않은 리소스를 조회하려다 에러가 발생하기 때문입니다.)
# 대신, main.tf에서 생성될 'aws_eks_cluster.main' 리소스를 직접 참조해야 합니다.

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  # [Best Practice] 토큰 방식 변경 (Data Source -> Exec)
  # 클러스터 생성 직후에는 토큰 데이터 소스가 불안정할 수 있어, 
  # AWS CLI를 통해 즉석에서 인증 토큰을 받아오는 방식이 가장 안전합니다.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    # Helm Provider에도 동일하게 AWS CLI 인증 방식을 적용합니다.
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
      command     = "aws"
    }
  }
}