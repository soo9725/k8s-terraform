# 03.5-middleware/data.tf

# 1. 원격 상태(Remote State) 참조
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "terraform-tfstate" # 1번에서 만든 버킷 이름
    key    = "02-cluster/terraform.tfstate" # 참조하려는 대상 레이어의 key 경로
    region = "ap-northeast-1"
  }
}

# 2. EKS 클러스터 정보 조회 (Provider 설정용)
data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}