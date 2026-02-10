variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-1" # 도쿄 리전
}

variable "project_name" {
  description = "Project Name"
  type        = string
  default     = "terraform-k8s"
}