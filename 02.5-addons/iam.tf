# 02.5-addons/iam.tf

# -------------------------------------------------------------
# 1. Karpenter Controller용 IRSA (Controller -> AWS API 호출용)
# -------------------------------------------------------------
module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name                          = "karpenter-controller-${var.cluster_name}"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id = var.cluster_name
  
  # Karpenter가 생성할 노드 Role의 ARN을 허용 목록에 추가
  karpenter_controller_node_iam_role_arns = [
    aws_iam_role.karpenter_node.arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = data.aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}

# [추가] 모듈에서 누락된 핵심 권한들을 직접 부착합니다.
resource "aws_iam_role_policy" "karpenter_controller_additional" {
  name = "karpenter-controller-additional-${var.cluster_name}"
  role = module.karpenter_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances", # [핵심 추가] 노드 삭제(Terminate)를 위해 필수적인 권한
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "pricing:GetProducts",
          "ssm:GetParameter",
          "iam:PassRole",
          # [핵심 추가] Spot 인스턴스 사용을 위한 서비스 연결 역할 생성 권한
          "iam:CreateServiceLinkedRole"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------------
# 2. Karpenter Node Role (새로 뜨는 노드가 가질 권한)
# -------------------------------------------------------------
resource "aws_iam_role" "karpenter_node" {
  name = "karpenter-node-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# 노드 필수 권한 부착 (EKS Worker Node 권한)
resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# Karpenter Node용 Instance Profile
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "karpenter-node-${var.cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# -----------------------------------------------------------
# [근본 해결] Karpenter 노드용 Access Entry 등록
# -----------------------------------------------------------
# 이 레이어에서 Role(aws_iam_role.karpenter_node)이 생성된 직후에 실행되므로
# 의존성 문제가 완벽하게 해결됩니다.

resource "aws_eks_access_entry" "karpenter_node" {
  # EKS 클러스터 이름 (변수 또는 remote_state 사용)
  cluster_name  = var.cluster_name 
  
  # 같은 파일 위쪽에서 정의한 Role의 ARN을 직접 참조
  principal_arn = aws_iam_role.karpenter_node.arn
  
  # 노드 자격 증명 타입
  type          = "EC2_LINUX"

  # 확실히 Role이 만들어진 후 실행되도록 보장
  depends_on = [aws_iam_role.karpenter_node]
}