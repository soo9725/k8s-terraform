# 02-cluster/outputs.tf

# ----------------------------------------------------------------
# EKS 클러스터 기본 정보 출력
# ----------------------------------------------------------------
output "cluster_name" {
  description = "생성된 EKS 클러스터 이름"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS 제어 센터(API Server) 접속 주소 (URL)"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "클러스터 인증서 데이터 (kubeconfig 설정용)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

# ----------------------------------------------------------------
# [중요] IRSA(IAM Role for Service Account) 설정을 위한 OIDC 정보
# ----------------------------------------------------------------
output "cluster_oidc_issuer_url" {
  description = "OIDC 제공자 URL (Karpenter 등 IRSA 설정용)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "IAM OIDC Provider ARN (Layer 4의 ALB Controller 권한 설정에 필수)"
  # 주의: 02-cluster/iam.tf 파일에 aws_iam_openid_connect_provider 리소스 이름이 'main'이어야 합니다.
  value       = aws_iam_openid_connect_provider.main.arn
}

# ----------------------------------------------------------------
# 노드 그룹 및 편의 기능
# ----------------------------------------------------------------
output "node_group_name" {
  description = "생성된 워커 노드 그룹 이름"
  value       = aws_eks_node_group.main.node_group_name
}

output "configure_kubectl" {
  description = "로컬 PC(또는 배스천)에서 kubectl을 연결하기 위한 명령어"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}