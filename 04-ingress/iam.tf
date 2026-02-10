# 04-ingress/iam.tf

# ----------------------------------------------------------------
# 1. IAM Policy for ALB Controller
# ----------------------------------------------------------------
# AWS 공식 리포지토리에서 최신 정책(JSON)을 다운로드합니다.
# 이렇게 하면 매번 JSON 파일을 복사/붙여넣기 하지 않아도 되어 관리가 편합니다.
data "http" "alb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project_name}-alb-controller-policy"
  path        = "/"
  description = "AWS Load Balancer Controller IAM Policy"
  policy      = data.http.alb_controller_iam_policy.response_body

  tags = {
    Name = "${var.project_name}-alb-controller-policy"
  }
}

# ----------------------------------------------------------------
# 2. IAM Role (IRSA - OIDC Trust Relationship)
# ----------------------------------------------------------------
# "이 역할은 EKS의 aws-load-balancer-controller 서비스 어카운트만 맡을 수 있다"는 신뢰 관계 설정
data "aws_iam_policy_document" "alb_controller_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      # Layer 2에서 넘어온 OIDC Provider ARN 사용
      identifiers = [data.terraform_remote_state.cluster.outputs.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      # OIDC URL에서 'https://'를 제거한 주소를 변수로 사용해야 함
      variable = "${replace(data.terraform_remote_state.cluster.outputs.cluster_oidc_issuer_url, "https://", "")}:sub"
      # 이 권한을 사용할 쿠버네티스 서비스 어카운트 지정 (Namespace:ServiceAccountName)
      values   = ["system:serviceaccount:ingress-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role_policy.json

  tags = {
    Name = "${var.project_name}-alb-controller-role"
  }
}

# ----------------------------------------------------------------
# 3. Policy Attachment
# ----------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ----------------------------------------------------------------
# 4. Output (Helm 설치 시 사용)
# ----------------------------------------------------------------
output "alb_controller_role_arn" {
  description = "ARN of IAM Role for ALB Controller"
  value       = aws_iam_role.alb_controller.arn
}