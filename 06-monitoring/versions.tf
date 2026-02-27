terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}
terraform {
  backend "s3" {
    bucket = "terraform-k8s-tfstate" # 1번에서 만든 버킷 이름 (변경했다면 그 이름 사용)
    key    = "06-monitoring/terraform.tfstate" # 해당 레이어의 폴더명으로 변경 
    region = "ap-northeast-1"
  }
}