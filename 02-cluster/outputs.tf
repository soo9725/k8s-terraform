# outputs.tf
# 생성된 EKS 클러스터의 접속 정보 및 중요 식별자를 출력합니다.

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

output "cluster_oidc_issuer_url" {
  description = "OIDC 제공자 URL (Karpenter 등 IRSA 설정용)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "node_group_name" {
  description = "생성된 워커 노드 그룹 이름"
  value       = aws_eks_node_group.main.node_group_name
}

# [편의 기능] 복사해서 바로 터미널에 붙여넣으면 되는 명령어
output "configure_kubectl" {
  description = "로컬 PC(또는 배스천)에서 kubectl을 연결하기 위한 명령어"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}