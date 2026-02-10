# main.tf
# EKS 클러스터(Control Plane)와 노드 그룹(Data Plane)을 생성합니다.

# -----------------------------------------------------------
# 1. EKS Cluster (Control Plane) 생성
# -----------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn     # iam.tf에서 만들 역할
  version  = var.cluster_version          # 1.30

  # 클러스터 네트워크 설정
  vpc_config {
    subnet_ids = concat(
      data.terraform_remote_state.network.outputs.public_subnet_ids,
      data.terraform_remote_state.network.outputs.private_subnet_ids
    )

    security_group_ids = [data.terraform_remote_state.network.outputs.vpc_default_security_group_id]

    endpoint_public_access  = true  # Bastion이나 로컬에서 kubectl 접속 허용
    endpoint_private_access = true  # 노드 간 내부 통신 허용
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

# -----------------------------------------------------------
# [수정됨] 노드 그룹용 시작 템플릿
# -----------------------------------------------------------
resource "aws_launch_template" "node_group" {
  name_prefix   = "${var.project_name}-node-"
  # [삭제됨] image_id = data.aws_ami.eks_default.id 
  # 이유: EKS Managed Node Group 사용 시 AMI ID를 여기서 지정하면 에러 발생.
  #       ami_type이 AL2_x86_64로 설정되어 있으므로 EKS가 알아서 최신 이미지를 선택함.
  
  instance_type = var.node_instance_types[0]

  # [핵심] 여기서 VPC Default SG를 강제로 입힙니다.
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.vpc_default_security_group_id
  ]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-node"
    }
  }
}

# -----------------------------------------------------------
# 2. EKS Node Group (System Node) 생성 - 템플릿 적용
# -----------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.terraform_remote_state.network.outputs.private_subnet_ids

  # 위에서 만든 Launch Template을 사용하도록 설정
  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  # EKS가 관리하는 Amazon Linux 2 이미지 사용
  ami_type = "AL2_x86_64"

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]

  update_config {
    max_unavailable = 1
  }
}

# -----------------------------------------------------------
# 3. EKS Add-ons
# -----------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.main]
}

# -----------------------------------------------------------
# 4. OIDC Provider [수정됨: 지문 하드코딩 적용]
# -----------------------------------------------------------
# [삭제] data "tls_certificate"는 불안정하므로 사용하지 않음

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  
  # [Best Practice] AWS EKS의 OIDC Root CA Thumbprint는 전 세계 공통값 사용
  # 동적으로 가져올 경우 Leaf 인증서를 가져오는 버그 방지
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# -----------------------------------------------------------
# 5. Bastion 보안 및 권한 설정
# -----------------------------------------------------------
resource "aws_security_group_rule" "allow_bastion_to_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = data.terraform_remote_state.network.outputs.vpc_default_security_group_id
  source_security_group_id = data.terraform_remote_state.network.outputs.bastion_security_group_id
  description              = "Allow HTTPS from Bastion to EKS Control Plane"
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.terraform_remote_state.network.outputs.bastion_iam_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.bastion.principal_arn
  access_scope {
    type = "cluster"
  }
}

resource "null_resource" "update_bastion_config" {
  depends_on = [
    aws_eks_cluster.main,
    aws_security_group_rule.allow_bastion_to_cluster,
    aws_eks_access_policy_association.bastion
  ]

  provisioner "remote-exec" {
    inline = [
      "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}"
    ]

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("~/.ssh/bastion_key")
      host        = data.terraform_remote_state.network.outputs.bastion_public_ip
    }
  }
}

# -----------------------------------------------------------
# 6. [접속 테스트용] NodePort 허용 규칙
# -----------------------------------------------------------
resource "aws_security_group_rule" "allow_nodeports_from_bastion" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 30031
  protocol                 = "tcp"
  
  # 규칙을 적용할 대상: VPC Default SG (Launch Template으로 노드에 강제 적용됨)
  security_group_id        = data.terraform_remote_state.network.outputs.vpc_default_security_group_id
  
  # 허용할 출발지: Bastion SG
  source_security_group_id = data.terraform_remote_state.network.outputs.bastion_security_group_id
  
  description              = "Allow Jenkins(30030) and ArgoCD(30031) from Bastion"
}

# -----------------------------------------------------------
# 7. [FIX] EBS CSI Driver (Storage) - 필수 추가
# -----------------------------------------------------------
# 노드 역할에 EBS 관리 권한 부여 (필수)
resource "aws_iam_role_policy_attachment" "node_ebs_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node.name
}

# EKS Add-on으로 드라이버 설치
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.31.0-eksbuild.1" # K8s 1.30 호환 버전
  service_account_role_arn = "" # 노드 IAM Role의 권한을 사용 (Simplicity)
  
  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.node_ebs_policy
  ]
}