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

# 1. EKS 클러스터의 OIDC Issuer URL에서 TLS 인증서 정보(Thumbprint)를 조회
data "tls_certificate" "main" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 2. IAM OIDC Identity Provider 생성
# (이것이 있어야 AWS IAM이 우리 EKS 클러스터를 "믿을 수 있는 인증 기관"으로 인식함)
resource "aws_iam_openid_connect_provider" "main" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  
  # 위에서 조회한 인증서의 지문(Thumbprint)을 등록
  thumbprint_list = [data.tls_certificate.main.certificates[0].sha1_fingerprint]
  
  tags = {
    Name = "${var.project_name}-oidc-provider"
  }
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
          Federated = aws_iam_openid_connect_provider.main.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:external-dns"
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