# provider.tf
# AWS 공급자(Provider)에 대한 구체적인 설정을 정의합니다.

provider "aws" {
  # 리전 설정: 직접 "ap-northeast-1"이라고 적지 않고 변수(var.region)를 사용합니다.
  # 이유는 나중에 리전을 바꿀 때 변수 파일만 고치면 되기 때문입니다.
  region = var.region

  # [Best Practice] 공통 태그 설정
  # 이 블록 안에 적은 태그는 앞으로 생성될 VPC, Subnet, EC2 등 모든 리소스에 자동으로 붙습니다.
  # 비용 관리(Cost Allocation)나 리소스 추적을 위해 필수적입니다.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"       # 개발 환경임을 명시
      ManagedBy   = "Terraform" # 테라폼으로 관리되는 리소스임을 명시 (중요!)
    }
  }
}
