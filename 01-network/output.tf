# outputs.tf
# 생성된 리소스의 주요 정보를 출력(Output)합니다.

# ----------------------------------------------------------------
# 1. Network Information (Permanent)
# ----------------------------------------------------------------
output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC의 CIDR 대역 (Layer 2에서 보안 그룹 규칙 만들 때 필요)"
  value       = var.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public Subnet ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private Subnet ID 목록 (EKS 노드가 배치될 곳)"
  value       = aws_subnet.private[*].id
}

output "vpc_default_security_group_id" {
  description = "VPC의 기본 보안 그룹 ID"
  value       = aws_vpc.main.default_security_group_id
}

# ----------------------------------------------------------------
# 2. Bastion Host Information (Conditional)
# ----------------------------------------------------------------
# [수정] Bastion이 없을 때(비용 절감 모드) 에러가 나지 않도록 조건 처리
output "bastion_public_ip" {
  description = "Bastion Host의 접속용 공인 IP (생성되었을 경우에만 출력)"
  # 리스트 길이(count)가 0보다 크면 IP 출력, 아니면 null 반환
  value       = length(aws_instance.bastion) > 0 ? aws_instance.bastion[0].public_ip : null
}

output "bastion_security_group_id" {
  description = "Bastion 보안 그룹 ID (EKS 노드에서 SSH 허용할 때 필요)"
  # 보안 그룹은 영구 유지되므로 조건문 불필요
  value       = aws_security_group.bastion.id
}

output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (Access Entry 자동화에 사용)"
  value       = length(aws_instance.bastion) > 0 ? aws_instance.bastion[0].id : null
}

# [NEW] Bastion IAM Role ARN (Layer 2에서 관리자 권한 부여 시 필수)
output "bastion_iam_role_arn" {
  description = "Bastion이 사용하는 IAM Role의 ARN"
  value       = aws_iam_role.bastion.arn
}

# ----------------------------------------------------------------
# 3. Storage Information (Persistence for Layer 2)
# ----------------------------------------------------------------
# [NEW] Jenkins가 데이터를 저장할 EFS ID
output "efs_id" {
  description = "Layer 1에 생성된 EFS 파일 시스템 ID (Jenkins 마운트용)"
  value       = aws_efs_file_system.main.id
}

# [NEW] Harbor가 이미지를 저장할 S3 버킷 이름
output "s3_bucket_name" {
  description = "Layer 1에 생성된 Harbor용 S3 버킷 이름"
  value       = aws_s3_bucket.harbor_storage.bucket
}

# [NEW] IAM 정책 설정 등에 필요한 S3 ARN
output "s3_bucket_arn" {
  description = "Layer 1에 생성된 Harbor용 S3 버킷 ARN"
  value       = aws_s3_bucket.harbor_storage.arn
}

output "efs_access_point_id" {
  value = aws_efs_access_point.jenkins.id
}