#!/bin/bash

# 에러 발생 시 즉시 스크립트 중단 (안전장치)
set -e

echo "🚀 [Start] 인프라 생성 및 비용 절감 해제를 시작합니다..."

# --------------------------------------
# 1. Layer 1: Network (NAT & Bastion 켜기)
# --------------------------------------
echo "--------------------------------------"
echo "🔌 Applying Layer 1 (Turning ON NAT & Bastion)..."
cd 01-network 
# [핵심] 변수를 true로 설정하여 NAT와 Bastion을 생성
terraform apply -var 'enable_nat_bastion=true' -auto-approve
cd ..

# --------------------------------------
# 2. Layer 2: Cluster (EKS 생성)
# --------------------------------------
echo "--------------------------------------"
echo "🏗️ Applying Layer 2 (Cluster)..."
cd 02-cluster 
terraform apply -auto-approve
# [필수] EKS가 새로 생성되었으므로 kubeconfig 업데이트
aws eks update-kubeconfig --region ap-northeast-1 --name terraform-k8s-cluster --alias k8s-demo
cd ..

# --------------------------------------
# 3. Layer 3: Registry & Apps (Harbor 등 설치)
# --------------------------------------
echo "--------------------------------------"
echo "📦 Applying Layer 3 (Registry & Apps)..."
cd 03-registry 
terraform apply -auto-approve
cd ..

# --------------------------------------
# 4. Layer 4: Ingress (ALB Controller 등)
# --------------------------------------
echo "--------------------------------------"
echo "🌐 Applying Layer 4 (Ingress)..."
cd 04-ingress 
terraform apply -auto-approve
cd ..

# --------------------------------------
# 5. ArgoCD Bootstrap (앱 배포 자동화)
# --------------------------------------
echo "--------------------------------------"
echo "🤖 Bootstrapping ArgoCD Apps..."

# Bootstrap 실행 (GitOps 트리거)
# bootstrap.yaml 파일은 apply_all.sh와 같은 위치(terraform-k8s 폴더)에 있어야 함
if [ -f "bootstrap.yml" ]; then
    kubectl apply -f bootstrap.yml
    echo "✅ Bootstrap applied successfully."
else
    echo "⚠️ Warning: bootstrap.yml not found. Skipping app deployment."
fi

# --------------------------------------
# 6. WebApp Ingress (ALB 생성 - 오늘 추가된 작업)
# --------------------------------------
echo "--------------------------------------"
echo "🌍 Exposing WebApp via ALB..."
if [ -f "05-app/ingress.yml" ]; then
    kubectl apply -f 05-app/ingress.yml
    echo "✅ Ingress applied."
else
    echo "⚠️ Warning: 05-app/ingress.yml not found."
fi

# --------------------------------------
# 7. ArgoCD 정보 출력 (비밀번호 확인용)
# --------------------------------------
echo "--------------------------------------"
echo "🔐 ArgoCD Admin Password:"
# 초기 비밀번호 디코딩하여 출력
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo "" # 줄바꿈

echo "--------------------------------------"
echo "✅ [Complete] 모든 인프라가 성공적으로 배포되었습니다!"