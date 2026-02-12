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
# 2.5 Layer 2.5: Add-ons (Karpenter & KEDA) [추가됨]
# --------------------------------------
echo "--------------------------------------"
echo "🔧 Applying Layer 2.5 (Add-ons: Karpenter, KEDA)..."
cd 02.5-addons
terraform apply -auto-approve
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

# ... (앞부분 스크립트 생략) ...

# --------------------------------------
# 8. 배포 상태 검증 (Verification)
# --------------------------------------
echo "--------------------------------------"
echo "🔍 [Verify] 리소스 상태 검증을 시작합니다 (최대 5분 대기)..."

# [함수 1] 모든 Pod가 Running 또는 Completed 인지 확인
check_pods() {
  # Running이나 Completed가 '아닌' 녀석들의 개수를 셉니다.
  # wc -l 은 개수를 세는 명령어입니다. grep -vE는 제외하는 명령어입니다.
  local not_ready_count=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l)
  echo "$not_ready_count"
}

# [함수 2] 모든 Ingress에 주소(ALB DNS)가 할당되었는지 확인
check_ingress() {
  local total_ingress=$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l)
  # Ingress가 아예 없으면 0을 반환 (성공으로 간주)
  if [ "$total_ingress" -eq 0 ]; then
    echo "0" # 남은 게 0개라는 의미
    return
  fi
  
  # ADDRESS 컬럼(보통 AWS 도메인)이 있는 녀석만 셉니다.
  local ready_ingress=$(kubectl get ingress -A --no-headers 2>/dev/null | grep ".amazonaws.com" | wc -l)
  
  # 전체 개수 - 준비된 개수 = 남은 개수
  echo $((total_ingress - ready_ingress))
}

# 최대 30번 반복 (30 * 10초 = 300초 = 5분)
MAX_RETRIES=30
ALL_READY=false

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY_PODS=$(check_pods)
  NOT_READY_INGRESS=$(check_ingress)

  # 둘 다 0이면 (모두 준비됨) 반복문 탈출
  if [ "$NOT_READY_PODS" -eq 0 ] && [ "$NOT_READY_INGRESS" -eq 0 ]; then
    ALL_READY=true
    break
  fi

  echo "   ⏳ 대기 중... (준비 안 된 Pod: $NOT_READY_PODS 개 / 주소 없는 Ingress: $NOT_READY_INGRESS 개)"
  sleep 10
done

echo "--------------------------------------"

if [ "$ALL_READY" = true ]; then
  # 요청하신 성공 메시지
  echo "✅ 모든 pod, ingress 가 정상 동작 중입니다."
else
  # 5분이 지나도 안 떴을 때
  echo "❌ 일부 리소스가 아직 준비되지 않았습니다. 수동 확인이 필요합니다."
  echo "   (Tip: kubectl get pods -A / kubectl get ingress -A 명령어로 확인하세요)"
fi