# iam.tf
# EKS 클러스터와 워커 노드가 AWS 서비스를 제어할 수 있도록 IAM 역할(Role)을 생성합니다.

# -----------------------------------------------------------
# 1. EKS Cluster IAM Role (클러스터 본체용)
# -----------------------------------------------------------
# AWS 서비스(eks.amazonaws.com)가 이 역할을 맡을 수 있도록 신뢰 관계 설정
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.project_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}

# [필수] 클러스터 운영 정책
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# [권장] 클러스터가 VPC 리소스(ENI, 보안그룹)를 제어하기 위한 정책
# (주석 해제: v1.30 환경에서 파드 보안 그룹 등 고급 네트워킹을 위해 권장됨)
resource "aws_iam_role_policy_attachment" "cluster_vpc_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}


# -----------------------------------------------------------
# 2. Node Group IAM Role (워커 노드용 - System Node)
# -----------------------------------------------------------
# EC2 서비스가 이 역할을 맡을 수 있도록 신뢰 관계 설정
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

# --- [워커 노드 필수 정책 3대장] ---

# 1) WorkerNodePolicy: 노드가 클러스터에 합류할 권한
resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

# 2) CNI_Policy: 노드가 파드에게 IP를 할당할 권한
resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

# 3) ContainerRegistryReadOnly: 노드가 ECR에서 이미지를 다운받을 권한
resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# --- [추가된 정책: 운영 및 데이터 영속성] ---

# 4) [NEW] SSM Managed Instance: SSH 없이 AWS 콘솔에서 노드 접속/디버깅 (Best Practice)
resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

# 5) [NEW] EFS CSI Driver Policy: Jenkins 데이터를 EFS에 저장/마운트하기 위해 필수
resource "aws_iam_role_policy_attachment" "node_efs_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.node.name
}

# -----------------------------------------------------------
# 3. Instance Profile
# -----------------------------------------------------------
# Karpenter가 스팟 인스턴스를 띄울 때 이 프로필을 사용합니다.
resource "aws_iam_instance_profile" "node" {
  name = "${var.project_name}-node-profile"
  role = aws_iam_role.node.name
}

# IRSA(IAM Role for Service Account)를 위한 OIDC Provider 설정 [필수]
# ----------------------------------------------------------------

# [Best Practice 수정] 1. 기존 OIDC Provider가 있는지 조회 (중복 생성 에러 방지)
data "aws_iam_openid_connect_provider" "existing" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# [Best Practice 수정] 2. 없으면 생성 (있으면 count=0으로 생성 안 함)
resource "aws_iam_openid_connect_provider" "main" {
  count = data.aws_iam_openid_connect_provider.existing.arn == null ? 1 : 0

  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  
  # [사용자 요청 유지] AWS EKS 전용 하드코딩된 Thumbprint 사용 (안정성 확보)
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  
  tags = {
    Name = "${var.project_name}-oidc-provider"
  }
}

# [Best Practice 수정] 3. 안전한 참조를 위한 로컬 변수 정의
# (기존 것이든, 새로 만든 것이든 유효한 ARN과 URL을 제공)
locals {
  oidc_provider_arn = data.aws_iam_openid_connect_provider.existing.arn != null ? data.aws_iam_openid_connect_provider.existing.arn : aws_iam_openid_connect_provider.main[0].arn
  oidc_provider_url = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# -----------------------------------------------------------
# 4. ExternalDNS IAM Role (Route53 제어용)
# -----------------------------------------------------------

# 1) Route53 제어 정책 (Allow All Route53 Actions)
resource "aws_iam_policy" "external_dns" {
  name        = "${var.project_name}-external-dns-policy"
  description = "Allow ExternalDNS to modify Route53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets"
        ]
        Resource = "*"
      }
    ]
  })
}

# 2) IAM Role (IRSA)
resource "aws_iam_role" "external_dns" {
  name = "${var.project_name}-external-dns-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # [수정] 리소스 직접 참조가 아닌 local 변수 참조
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # [수정] 리소스 직접 참조가 아닌 local 변수 참조
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:external-dns"
          }
        }
      }
    ]
  })
}

# 3) 정책 연결
resource "aws_iam_role_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.external_dns.arn
  role       = aws_iam_role.external_dns.name
}