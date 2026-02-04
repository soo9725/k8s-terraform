# variables.tf
# 인프라 구축에 사용되는 변수(설정값)들을 정의합니다.

variable "region" {
  description = "AWS 리전 (도쿄)"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "프로젝트 이름 (태그 및 리소스 이름에 사용)"
  type        = string
  default     = "terraform-k8s"
}

variable "vpc_cidr" {
  description = "VPC 전체 IP 대역"
  type        = string
  default     = "172.16.0.0/16"
}

# [중요] 가용 영역 (Availability Zones)
# 도쿄 리전은 보통 1a, 1c, 1d를 사용합니다. (1b는 구형 인스턴스 제한이 있는 경우가 많음)
# 고가용성(HA)을 위해 2개의 AZ를 지정합니다.
variable "availability_zones" {
  description = "사용할 가용 영역 목록"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

# Public Subnet (외부 통신 가능) - ALB, Bastion, NAT가 위치함
variable "public_subnets" {
  description = "Public Subnet CIDR 목록"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24"]
}

# Private Subnet (외부 통신 차단) - EKS 노드, DB 등이 위치함
variable "private_subnets" {
  description = "Private Subnet CIDR 목록"
  type        = list(string)
  default     = ["172.16.10.0/24", "172.16.20.0/24"]
}

variable "key_name" {
  description = "AWS에 등록될 키 페어의 이름"
  type        = string
  default     = "bastion_key" 
}

# 비용 절감 스위치 변수
# true: NAT, Bastion 생성 (업무 시간) -> 비용 발생 O
# false: NAT, Bastion 삭제 (퇴근 시간) -> 비용 절감 (VPC, EFS, S3는 유지됨)
variable "enable_nat_bastion" {
  description = "NAT Gateway와 Bastion Host 생성 여부 (비용 절감용 토글)"
  type        = bool
  default     = true
}