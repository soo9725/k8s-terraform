#!/bin/bash

# 에러 발생 시 즉시 스크립트 중단 (안전장치)
set -e

echo "🚀 [Start] 인프라 생성 및 비용 절감 해제를 시작합니다..."

# 1. Layer 1: Network (NAT & Bastion 켜기)
echo "--------------------------------------"
echo "🔌 Applying Layer 1 (Turning ON NAT & Bastion)..."
cd 01-network 
# [핵심] 변수를 true로 설정하여 NAT와 Bastion을 생성
terraform apply -var 'enable_nat_bastion=true' -auto-approve
cd ..

# 2. Layer 2: Cluster (EKS 생성)
echo "--------------------------------------"
echo "🏗️ Applying Layer 2 (Cluster)..."
cd 02-cluster 
terraform apply -auto-approve
# [필수] EKS가 새로 생성되었으므로 kubeconfig 업데이트
aws eks update-kubeconfig --region ap-northeast-1 --name terraform-k8s-cluster --alias k8s-demo
cd ..

# 3. Layer 3: Registry & Apps (Harbor 등 설치)
echo "--------------------------------------"
echo "📦 Applying Layer 3 (Registry & Apps)..."
cd 03-registry 
terraform apply -auto-approve
cd ..

# 4. Layer 4: Ingress (ALB Controller 등)
# (아직 안 만드셨으면 주석 처리)
# echo "--------------------------------------"
# echo "🌐 Applying Layer 4 (Ingress)..."
# cd 04-ingress 
# terraform apply -auto-approve
# cd ..

echo "✅ [Complete] 모든 인프라가 성공적으로 배포되었습니다!"