# 03-registry/iam.tf

# 1. Policy (변동 없음)
resource "aws_iam_policy" "harbor_s3" {
  name        = "${var.project_name}-harbor-s3-policy"
  description = "Allow Harbor to access S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = data.terraform_remote_state.network.outputs.s3_bucket_arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${data.terraform_remote_state.network.outputs.s3_bucket_arn}/*"
      }
    ]
  })
}

# 2. Role (핵심 수정: StringLike + 와일드카드)
locals {
  oidc_url = replace(data.terraform_remote_state.cluster.outputs.cluster_oidc_issuer_url, "https://", "")
}

resource "aws_iam_role" "harbor" {
  name = "${var.project_name}-harbor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_url}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          # [여기!] StringEquals -> StringLike로 변경
          # default든 harbor-registry든 harbor 네임스페이스면 전부 허용
          StringLike = {
            "${local.oidc_url}:sub" = "system:serviceaccount:harbor:*"
            "${local.oidc_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# 3. Attachment (변동 없음)
resource "aws_iam_role_policy_attachment" "harbor_s3" {
  policy_arn = aws_iam_policy.harbor_s3.arn
  role       = aws_iam_role.harbor.name
}

# -------------------------------------------------------------
# [긴급 처방] Node Role에 S3 권한 직접 부여
# Harbor가 IRSA를 무시하고 Node Role을 사용할 경우를 대비한 2차 안전장치
# -------------------------------------------------------------

# 1. Layer 2에서 만든 Node Role을 이름으로 찾는다.
# (로그에 찍힌 이름: terraform-k8s-node-role)
data "aws_iam_role" "node_role" {
  name = "${var.project_name}-node-role"
}

# 2. 이미 만들어둔 S3 정책(harbor_s3)을 노드 역할에도 붙여버린다.
resource "aws_iam_role_policy_attachment" "node_s3_fallback" {
  policy_arn = aws_iam_policy.harbor_s3.arn
  role       = data.aws_iam_role.node_role.name
}