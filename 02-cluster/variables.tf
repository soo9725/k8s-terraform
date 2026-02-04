# variables.tf
# Layer 2 (EKS 클러스터) 전용 변수 정의

# --- [공통 변수] Layer 1과 동일하게 맞춰줍니다 ---
variable "region" {
  description = "AWS 리전 (도쿄)"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "terraform-k8s"
}

# --- [EKS 전용 변수] Layer 2만의 설정 ---

# [NEW] provider.tf에서 참조하는 클러스터 이름 변수 추가
variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "terraform-k8s-cluster"
}

# 1. 쿠버네티스 버전
# 너무 최신(1.32)보다는 안정적인 버전을 추천합니다. (호환성 이슈 방지)
variable "cluster_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.30"
}

# 2. 워커 노드(서버) 인스턴스 타입
# m7i-flex.large: 최신 4세대 인텔 CPU, 가성비 우수
variable "node_instance_types" {
  description = "워커 노드 인스턴스 타입 목록"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

# 3. 워커 노드 개수 (Auto Scaling 설정)
# 평소엔 2대, 바쁘면 최대 3대까지 늘어남
variable "node_min_size" {
  description = "최소 노드 개수"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "최대 노드 개수"
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "희망 노드 개수 (초기 생성 시)"
  type        = number
  default     = 2
}