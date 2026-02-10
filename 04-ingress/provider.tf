# 04-ingress/provider.tf

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Layer       = "04-ingress"
    }
  }
}

# ----------------------------------------------------------------
# Kubernetes & Helm Provider Configuration
# ----------------------------------------------------------------
# Layer 2에서 만든 EKS 클러스터의 접속 정보를 받아와서 설정합니다.
# (이 정보는 data.tf에서 정의할 'data.aws_eks_cluster'에서 옴)

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.main.name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.main.name]
      command     = "aws"
    }
  }
}