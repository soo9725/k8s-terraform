# versions.tf
# Terraform 및 Provider(플러그인)의 버전 제약 조건을 정의합니다.

terraform {
  # Terraform CLI(실행 도구)의 최소 버전을 지정합니다.
  # 1.0.0 이상이면 실행되도록 허용합니다.
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # "5.0 이상 6.0 미만"의 버전을 사용하도록 고정합니다. (예: 5.88.0)
      # 6.0 등 메이저 버전이 바뀌어서 코드가 깨지는 것을 방지합니다.
      version = "~> 5.0"
    }
  }
}