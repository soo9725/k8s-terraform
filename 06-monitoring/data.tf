# Layer 2 (Cluster) 상태 참조
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../02-cluster/terraform.tfstate"
  }
}

# EKS 클러스터 접속 정보 조회
data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}