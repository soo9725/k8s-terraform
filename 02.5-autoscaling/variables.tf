variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "cluster_name" {
  description = "EKS Cluster Name"
  type        = string
  default     = "terraform-k8s-cluster"
}

variable "project_name" {
  description = "Project Name"
  type        = string
  default     = "terraform-k8s"
}