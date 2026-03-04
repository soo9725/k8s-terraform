# OIDC Provider 정보 조회 (Layer 2에서 생성된 것)
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}