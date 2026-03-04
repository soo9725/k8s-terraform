#!/bin/bash
set -e
echo "🚨 [Start] 전체 인프라 삭제를 시작합니다..."

# --------------------------------------
# 0. [중요] K8s 리소스 정리 (좀비 리소스 방지)
# --------------------------------------
echo "--------------------------------------"
echo "🧹 Cleaning up Kubernetes Resources (To prevent Zombie ALB & Nodes)..."

# 1. ArgoCD 동기화 해제
echo "   - Disabling ArgoCD Auto-Sync..."
kubectl get applications -n argocd -o name | xargs -I {} kubectl patch {} -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true

# ------------------------------------------------------------------------------
# [업그레이드] CRD Finalizer 일괄 제거 (동적 탐색)
# 일일이 이름을 적지 않고, API Group을 기반으로 모든 CRD를 자동으로 찾아 잠금을 해제합니다.
# (PrometheusAgent, KafkaUser 등 누락된 리소스까지 완벽하게 처리)
# ------------------------------------------------------------------------------
echo "   - 🔓 Unlocking Finalizers for all critical CRDs (Dynamic Scan)..."

# 처리할 대상 API 그룹 목록
# monitoring.coreos.com : 프로메테우스 스택 전반 (Agent 포함)
# kafka.strimzi.io      : 카프카, 토픽, 유저, 커넥터 등 전체
# keda.sh               : KEDA 관련 전체
# karpenter.sh          : 카펜터 노드풀 등
# karpenter.k8s.aws     : 카펜터 EC2NodeClass 등
TARGET_API_GROUPS=(
  "monitoring.coreos.com"
  "kafka.strimzi.io"
  "keda.sh"
  "karpenter.sh"
  "karpenter.k8s.aws"
  "argoproj.io"
)

for group in "${TARGET_API_GROUPS[@]}"; do
  echo "     🔍 Scanning API Group: $group..."
  # 해당 그룹의 모든 CRD 이름 조회 (에러 무시)
  CRD_LIST=$(kubectl api-resources --api-group="$group" -o name 2>/dev/null || true)

  if [ -z "$CRD_LIST" ]; then
    continue
  fi

  for crd in $CRD_LIST; do
    echo "       -> Unlocking $crd..."
    # 해당 CRD의 모든 리소스(모든 네임스페이스)의 Finalizer 제거
    kubectl get "$crd" -A -o name 2>/dev/null | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
done

# 3. Kafka 리소스 정리 (명시적 삭제 요청 유지)
# 위에서 잠금은 풀었지만, 깔끔한 상태를 위해 명시적 삭제 명령은 유지합니다.
echo "   - Deleting Kafka Resources..."
kubectl delete kafka --all -n kafka --ignore-not-found=true --timeout=30s || echo "⚠️ Kafka deletion timed out, proceeding..."

# 4. KEDA 리소스 정리 (설정 파일 기반 삭제 유지)
echo "   - Deleting KEDA Resources..."
if [ -f "05-app/kedaconfig.yml" ]; then
  kubectl delete -f 05-app/kedaconfig.yml --ignore-not-found=true
fi
# 혹시 파일에 없는 찌꺼기 삭제
kubectl delete scaledobject --all -A --ignore-not-found=true
kubectl delete triggerauthentication --all -A --ignore-not-found=true

# 5. Karpenter 리소스 정리 (노드 삭제 요청)
echo "   - Deleting Karpenter Resources..."
# 노드 먼저 삭제 요청 (60초 타임아웃) - 잠금은 위에서 다 풀렸으므로 빨리 지워질 것임
kubectl delete nodeclaims --all --timeout=60s || echo "⚠️ NodeClaim deletion timed out, forcing..."

# API 안정화 대기
echo "⏳ Waiting for K8s API to stabilize (10s)..."
sleep 10

# 6. ArgoCD 앱 삭제
echo "   - Deleting ArgoCD Applications..."
kubectl delete application app -n argocd --ignore-not-found --wait=true || kubectl patch application app -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge

# 7. Ingress 삭제 (수동 생성분)
kubectl delete -f 05-app/ingress.yml --ignore-not-found
kubectl delete ingress -A --all --ignore-not-found

# 8. ALB 삭제 확인 (가장 중요)
echo "⏳ Verifying ALB deletion..."
for i in {1..30}; do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName, 'k8s')].LoadBalancerArn" --output text | wc -w)
  if [ "$ALB_COUNT" -eq 0 ]; then
    echo "✅ No ALBs found. Safe to proceed."
    break
  fi
  echo "⚠️ $ALB_COUNT ALB(s) still exist. Waiting 10s... ($i/30)"
  sleep 10
done
if [ "$ALB_COUNT" -gt 0 ]; then
  echo "🚨 WARNING: ALBs might still exist! Please check AWS Console."
fi

# ... (이후 Terraform Destroy 부분은 기존과 동일하므로 생략하지 않고 전체 코드블럭 사용 시 포함됩니다) ...
# --------------------------------------
# 1. Layer 6: Monitoring (Terraform Destroy)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 6 (Monitoring)..."
if [ -d "06-monitoring" ]; then
  cd 06-monitoring && terraform init && terraform destroy -auto-approve && cd ..
else
  echo "⚠️ 06-monitoring directory not found, skipping..."
fi

# --------------------------------------
# 2. Layer 5: Application (Terraform Destroy)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 5 (App)..."
if [ -d "05-app" ]; then
  cd 05-app && terraform init && terraform destroy -auto-approve && cd ..
else
  echo "⚠️ 05-app directory not found, skipping..."
fi

# --------------------------------------
# 3. Layer 4: Ingress (Terraform Destroy)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 4 (Ingress)..."
cd 04-ingress && terraform init && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 4. Layer 3.5: Middleware (Kafka)
# --------------------------------------
echo "--------------------------------------"
echo "📨 Destroying Layer 3.5 (Kafka Middleware)..."
cd 03.5-kafka && terraform init && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 5. Layer 3: Registry & Apps
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 3 (Registry)..."
cd 03-harbor && terraform init && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 6. Layer 2.5: Add-ons (Karpenter & KEDA)
# --------------------------------------
echo "--------------------------------------"
echo "🔧 Destroying Layer 2.5 (Add-ons: Karpenter, KEDA)..."
cd 02.5-autoscaling && terraform init && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 7. Layer 2: Cluster (EKS) & OIDC Cleanup
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 2 (Cluster)..."
cd 02-cluster && terraform init

# OIDC Cleanup Logic
OIDC_URL=$(aws eks describe-cluster --name terraform-k8s-cluster --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || echo "")
OIDC_ID=$(echo $OIDC_URL | awk -F/ '{print $NF}')

terraform destroy -auto-approve

if [ -n "$OIDC_ID" ]; then
  echo "🔎 Checking for leftover OIDC Provider: $OIDC_ID"
  OIDC_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ID')].Arn" --output text)
  if [ -n "$OIDC_ARN" ] && [ "$OIDC_ARN" != "None" ]; then
    echo "🧟 Zombie OIDC found. Deleting $OIDC_ARN..."
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
    echo "✅ OIDC Provider cleaned up."
  else
    echo "✅ No Zombie OIDC Provider found."
  fi
fi
cd ..

# --------------------------------------
# 8. Layer 1: Network (비용 절감 모드)
# --------------------------------------
echo "--------------------------------------"
echo "💸 Saving Cost: Layer 1 (Turning off NAT & Bastion)..."
cd 01-network
terraform init
terraform apply -var 'enable_nat_bastion=false' -auto-approve
cd ..

echo "✅ [Complete] 모든 리소스가 안전하게 삭제되었습니다. (비용 절감 모드 전환 완료)"