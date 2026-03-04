# 03-registry/variables.tf

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project Name"
  type        = string
  default     = "terraform-k8s"
}

# [NEW] 도메인 변수 추가
variable "domain_name" {
  description = "Route53 Hosted Zone Domain Name"
  type        = string
  default     = "soo9725.site"
}

# [NEW] ACM 인증서 ARN 추가 (Layer 2와 동일한 값)
variable "acm_certificate_arn" {
  description = "AWS ACM Certificate ARN"
  type        = string
  default     = "arn:aws:acm:ap-northeast-1:894168368940:certificate/f9e48831-30dd-4343-849a-b964ed021783"
}