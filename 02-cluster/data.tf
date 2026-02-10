# data.tf
# Layer 1(Network)의 상태(State)를 읽어와서 정보를 참조합니다.

# 1. 원격 상태(Remote State) 참조
# 01-network의 terraform.tfstate 파일을 읽습니다.
# 여기서 vpc_id, subnet_ids 뿐만 아니라
# [NEW] efs_id, s3_bucket_name 같은 스토리지 정보도 다 가져옵니다.
data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    # Layer 1의 State 파일 경로 (상대 경로 정확해야 함)
    path = "${path.module}/../01-network/terraform.tfstate"
  }
}

# 2. AWS 가용 영역(AZ) 정보 조회
data "aws_availability_zones" "available" {}

# 3. 현재 AWS 계정 정보 조회 (EKS 접근 권한 및 IAM 설정용)
data "aws_caller_identity" "current" {}

# 4. Amazon Linux 2023 EKS Optimized AMI 조회
# EKS 노드용 최신 OS 이미지를 찾습니다.
# variables.tf에 정의될 var.cluster_version(1.30)을 사용합니다.
data "aws_ami" "eks_default" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    # 예: amazon-eks-node-1.30-v20241001
    values = ["amazon-eks-node-${var.cluster_version}-v*"]
  }
}