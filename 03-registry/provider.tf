# 03-registry/provider.tf

# 1. AWS 설정 (리전 정보)
provider "aws" {
  region = var.region
}

# 2. Kubernetes 접속 정보 (Layer 2에서 주소와 인증서를 가져옴)
provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.cluster.outputs.cluster_name]
    command     = "aws"
  }
}

# 3. Helm 접속 정보 (Kubernetes와 동일하게 설정해야 EKS에 설치 가능)
provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.cluster.outputs.cluster_name]
      command     = "aws"
    }
  }
}