# main.tf

# ----------------------------------------------------------------
# 0. Data Sources (AMI 조회)
# ----------------------------------------------------------------
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ----------------------------------------------------------------
# 1. VPC 및 기본 네트워크 (영구 유지)
# ----------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ----------------------------------------------------------------
# 2. Subnets (영구 유지)
# ----------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery" = var.project_name
  }
}

# ----------------------------------------------------------------
# 3. NAT Gateway (조건부 생성 - 비용 절감 핵심)
# ----------------------------------------------------------------
# [Toggle] enable_nat_bastion이 true일 때만 EIP 생성
resource "aws_eip" "nat" {
  count  = var.enable_nat_bastion ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

# [Toggle] enable_nat_bastion이 true일 때만 NAT Gateway 생성
resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_bastion ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  # 첫 번째 Public Subnet에 배치
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${var.project_name}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# ----------------------------------------------------------------
# 4. Routing Table
# ----------------------------------------------------------------
# (1) Public Routing (항상 IGW로 연결)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# (2) Private Routing (NAT가 있을 때만 연결)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-private-rt" }
}

# [Toggle] NAT가 켜져 있을 때만: 0.0.0.0/0 -> NAT Gateway 라우팅 규칙 생성
# NAT가 꺼지면 Private Subnet은 외부와 통신 불가능 (비용 절감 상태)
resource "aws_route" "private_nat" {
  count                  = var.enable_nat_bastion ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ----------------------------------------------------------------
# 5. Bastion Host (조건부 생성)
# ----------------------------------------------------------------

# 보안 그룹은 리소스가 작으므로 영구 유지 (재생성 시 ID 변경 방지)
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "Allow SSH inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from Anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-bastion-sg" }
}

# 키 페어 등록 (영구 유지 - 매번 등록 귀찮음 방지)
resource "aws_key_pair" "bastion" {
  key_name   = var.key_name
  public_key = file("~/.ssh/bastion_key.pub") 
}

# [Toggle] Bastion EC2 인스턴스 (조건부 생성)
resource "aws_instance" "bastion" {
  count         = var.enable_nat_bastion ? 1 : 0
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  
  subnet_id              = aws_subnet.public[0].id
  key_name               = aws_key_pair.bastion.key_name
  vpc_security_group_ids = [aws_security_group.bastion.id]
  
  # [수정] 아래에서 정의한 IAM Profile 연결 (권한 문제 해결 핵심)
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # 부팅 시 kubectl, aws-cli, helm, docker 자동 설치 스크립트
user_data = <<-EOF
              #!/bin/bash
              
              # -------------------------------------------
              # 1. Kubectl 설치
              # -------------------------------------------
              curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl
              chmod +x ./kubectl
              mv ./kubectl /usr/local/bin/kubectl
              
              # -------------------------------------------
              # 2. AWS CLI 업데이트
              # -------------------------------------------
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              sudo ./aws/install --update

              # -------------------------------------------
              # 3. Helm 설치
              # -------------------------------------------
              curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

              # -------------------------------------------
              # 4. [추가됨] Docker 설치 및 실행
              # -------------------------------------------
              yum update -y
              yum install -y docker
              systemctl enable --now docker
              usermod -aG docker ec2-user
              EOF

  tags = { Name = "${var.project_name}-bastion" }
}

# ----------------------------------------------------------------
# 6. Bastion IAM Role (수정됨 - 슈퍼 Bastion)
# ----------------------------------------------------------------
# 1) Bastion이 역할을 수행할 수 있도록 신뢰 관계 설정
data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# 2) IAM Role 생성
resource "aws_iam_role" "bastion" {
  name               = "${var.project_name}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json
}

# 3) [중요] 관리자 권한(AdministratorAccess) 부여
# 이제 Bastion은 EKS뿐만 아니라 모든 AWS 리소스를 제어할 수 있는 슈퍼 권한을 가집니다.
# (실습 환경에서의 Unauthorized 문제 100% 해결)
resource "aws_iam_role_policy_attachment" "bastion_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.bastion.name
}

# 4) 인스턴스 프로파일 생성 (EC2에 부착용)
resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ----------------------------------------------------------------
# 7. [NEW] 영구 스토리지 - EFS (Jenkins 데이터 보존용)
# ----------------------------------------------------------------
# EFS용 보안 그룹 (VPC 내부 통신 허용)
resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "Allow NFS traffic from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NFS from VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  tags = { Name = "${var.project_name}-efs-sg" }
}

# EFS 파일 시스템 본체 (절대 삭제 안됨)
resource "aws_efs_file_system" "main" {
  creation_token = "${var.project_name}-efs"
  encrypted      = true

  tags = { Name = "${var.project_name}-efs" }
}

# EFS 마운트 타겟 (Private Subnet에 연결)
resource "aws_efs_mount_target" "main" {
  count           = length(var.private_subnets)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# [추가됨] Jenkins를 위한 영구 Access Point (고정된 데이터 경로)
resource "aws_efs_access_point" "jenkins" {
  file_system_id = aws_efs_file_system.main.id

  # POSIX 사용자 (Jenkins 실행 유저: 1000)
  posix_user {
    gid = 1000
    uid = 1000
  }

  # EFS 내부의 고정된 디렉토리 경로
  root_directory {
    path = "/jenkins-home"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.project_name}-jenkins-ap"
  }
}

# ----------------------------------------------------------------
# 8. [NEW] 영구 스토리지 - S3 (Harbor 이미지 저장용)
# ----------------------------------------------------------------
resource "aws_s3_bucket" "harbor_storage" {
  # 버킷 이름 충돌 방지를 위해 랜덤 날짜/시간 추가
  bucket = "${var.project_name}-harbor-storage-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  
  # 실습 편의상 강제 삭제 허용 (실무에선 false 권장)
  force_destroy = true 

  tags = { Name = "${var.project_name}-harbor-storage" }
}