terraform {
  backend "s3" {
    bucket = "terraform-k8s-tfstate" # 1번에서 만든 버킷 이름 (변경했다면 그 이름 사용)
    key    = "02-cluster/terraform.tfstate" # 해당 레이어의 폴더명으로 변경 
    region = "ap-northeast-1"
  }
}