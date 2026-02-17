# 03.5-middleware/data.tf

# 1. 원격 상태(Remote State) 참조
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../02-cluster/terraform.tfstate"
  }
}

# 2. EKS 클러스터 정보 조회 (Provider 설정용)
data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}