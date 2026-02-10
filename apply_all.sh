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
terraform apply -var 'enable_nat_bastion=true' -auto-approve
cd ..

# --------------------------------------
# 2. Layer 2: Cluster (EKS 생성)
# --------------------------------------
echo "--------------------------------------"
echo "🏗️ Applying Layer 2 (Cluster)..."
cd 02-cluster 

# [FIX] 실패했을 경우(! 연산자)에만 OIDC 복구 로직 실행
if ! terraform apply -auto-approve; then
  echo "⚠️ Terraform apply failed. Checking for OIDC Provider issues..."
  
  # kubeconfig 업데이트
  aws eks update-kubeconfig --region ap-northeast-1 --name terraform-k8s-cluster --alias k8s-demo 2>/dev/null

  # OIDC Issuer URL 확인
  ISSUER_URL=$(aws eks describe-cluster --name terraform-k8s-cluster --query "cluster.identity.oidc.issuer" --output text 2>/dev/null)
  
  if [ -n "$ISSUER_URL" ]; then
    OIDC_ID=$(echo $ISSUER_URL | awk -F/ '{print $NF}')
    echo "🔎 Detected OIDC ID: $OIDC_ID"
    
    # IAM에서 해당 ID 검색
    EXISTING_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ID')].Arn" --output text)
    
    if [ -n "$EXISTING_ARN" ]; then
      echo "🧟 Zombie OIDC Provider found: $EXISTING_ARN"
      echo "🚑 Attempting auto-import..."
      
      terraform import aws_iam_openid_connect_provider.eks "$EXISTING_ARN"
      
      echo "🔄 Retrying Terraform Apply..."
      terraform apply -auto-approve
    else
      echo "❌ OIDC issue detected but no existing provider found. Please check logs manually."
      exit 1
    fi
  else
    echo "❌ Failed to retrieve Cluster OIDC URL. Aborting."
    exit 1
  fi
fi

# 성공 시 kubeconfig 업데이트
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

# [FIX] ALB Controller가 Ingress를 인식할 수 있도록 잠시 대기
echo "⏳ Waiting for ALB Controller to initialize (15s)..."
sleep 15

# --------------------------------------
# 5. ArgoCD Bootstrap (앱 배포 자동화)
# --------------------------------------
echo "--------------------------------------"
echo "🤖 Bootstrapping ArgoCD Apps..."

if [ -f "bootstrap.yml" ]; then
    kubectl apply -f bootstrap.yml
    echo "✅ Bootstrap applied successfully."
else
    echo "⚠️ Warning: bootstrap.yml not found. Skipping app deployment."
fi

# --------------------------------------
# 6. WebApp Ingress (ALB 생성)
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
# 7. ArgoCD 정보 출력
# --------------------------------------
echo "--------------------------------------"
echo "🔐 ArgoCD Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo "" 

echo "--------------------------------------"
echo "✅ [Complete] 모든 인프라가 성공적으로 배포되었습니다!"