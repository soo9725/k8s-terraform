# 04-ingress/variables.tf

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project Name (Tagging 및 Naming 접두사)"
  type        = string
  default     = "terraform-k8s"
}

variable "environment" {
  description = "Environment (dev, prod, etc.)"
  type        = string
  default     = "dev"
}

# ----------------------------------------------------------------
# Helm Chart Version Control (버전 고정 = 안정성)
# ----------------------------------------------------------------
variable "alb_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm Chart Version"
  type        = string
  default     = "1.7.1" # 최신 안정 버전 (2024년 기준 v2.7.x 앱 버전과 매핑됨)
}

variable "alb_controller_chart_repo" {
  description = "AWS Load Balancer Controller Helm Repository"
  type        = string
  default     = "https://aws.github.io/eks-charts"
}