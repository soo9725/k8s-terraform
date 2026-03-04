# 04-ingress/data.tf

# ----------------------------------------------------------------
# Remote State: Layer 2 (Cluster) 정보 가져오기
# ----------------------------------------------------------------
# Layer 2에서 출력한 outputs(OIDC ARN, 클러스터 이름 등)를 읽어옵니다.
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "terraform-k8s-tfstate" # 1번에서 만든 버킷 이름
    key    = "02-cluster/terraform.tfstate" # 참조하려는 대상 레이어의 key 경로
    region = "ap-northeast-1"
  }
}

# ----------------------------------------------------------------
# EKS Cluster Data Source
# ----------------------------------------------------------------
# provider.tf 에서 접속 정보를 설정하기 위해 실시간 클러스터 정보를 조회합니다.
data "aws_eks_cluster" "main" {
  # Remote State에서 클러스터 이름을 가져옴
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}