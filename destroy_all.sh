#!/bin/bash
set -e
echo "🚨 [Start] 전체 인프라 삭제를 시작합니다..."

# --------------------------------------
# 0. [중요] K8s 리소스 정리 (좀비 리소스 방지)
# --------------------------------------
echo "--------------------------------------"
echo "🧹 Cleaning up Kubernetes Resources (To prevent Zombie ALB & Nodes)..."

# [핵심 추가] KEDA 리소스가 오퍼레이터 삭제 전 확실히 사라지도록 Finalizer 선제 제거
# 청소부(Operator)가 먼저 퇴근하기 전에 쓰레기(ScaledObject)의 잠금을 미리 푸는 작업입니다.
echo "   - Patching KEDA Finalizers (To prevent timeout)..."
kubectl get scaledobject -A -o name | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
kubectl get triggerauthentication -A -o name | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true

echo "   - Deleting KEDA ScaledObjects..."
# 파일이 존재하면 파일 기준으로 삭제
if [ -f "05-app/kedaconfig.yml" ]; then
  kubectl delete -f 05-app/kedaconfig.yml --ignore-not-found=true
fi

# (안전장치) 파일이 없거나 찌꺼기가 남았을 경우를 대비해 강제 삭제
kubectl delete scaledobject --all -A --ignore-not-found=true
kubectl delete triggerauthentication --all -A --ignore-not-found=true

echo "   - Deleting Karpenter Resources..."
# 1. 노드 먼저 삭제 요청 (60초 타임아웃)
kubectl delete nodeclaims --all --timeout=60s || echo "⚠️ NodeClaim deletion timed out, forcing..."

# 2. 오늘 겪었던 교착 상태 방지 (강제 패치: Finalizer 제거)
kubectl get nodeclaims -o name | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
kubectl get nodes -l karpenter.sh/nodepool=default -o name | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true

# [Best Practice] 리소스가 완전히 정리될 수 있도록 잠시 대기
echo "⏳ Waiting for K8s API to stabilize (10s)..."
sleep 10

# ArgoCD 앱 삭제 (파이널라이저 때문에 안 지워지는 경우 강제 삭제)
# 앱이 삭제되어야 연관된 LoadBalancer/Ingress가 정리됨
echo "   - Deleting ArgoCD Applications..."
kubectl delete application app -n argocd --ignore-not-found --wait=true || kubectl patch application app -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge

# Ingress 삭제 (수동으로 apply 했던 것들)
kubectl delete -f 05-app/ingress.yml --ignore-not-found
kubectl delete ingress -A --all --ignore-not-found

# [Best Practice] ALB가 완전히 사라질 때까지 대기 (최대 5분)
echo "⏳ Verifying ALB deletion..."
# EKS 클러스터와 연관된 ALB가 있는지 확인하는 루프
for i in {1..30}; do
  # "k8s" 태그가 포함된 ALB가 있는지 조회 (k8s로 시작하는 ALB)
  ALB_COUNT=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName, 'k8s')].LoadBalancerArn" --output text | wc -w)
  
  if [ "$ALB_COUNT" -eq 0 ]; then
    echo "✅ No ALBs found. Safe to proceed."
    break
  fi
  
  echo "⚠️ $ALB_COUNT ALB(s) still exist. Waiting 10s... ($i/30)"
  sleep 10
done

# 루프가 끝나도 ALB가 남아있으면 경고 (하지만 강제로 진행하진 않음, 사용자가 볼 수 있게)
if [ "$ALB_COUNT" -gt 0 ]; then
  echo "🚨 WARNING: ALBs might still exist! Please check AWS Console."
fi

# --------------------------------------
# 1. Layer 4: Ingress (Terraform Destroy)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 4 (Ingress)..."
cd 04-ingress && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 2. Layer 3: Registry & Apps
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 3 (Registry)..."
cd 03-registry && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 3. Layer 2.5: Add-ons (Karpenter & KEDA) [추가됨]
# --------------------------------------
# Karpenter가 만든 노드가 있다면 여기서 정리되어야 함
echo "--------------------------------------"
echo "🔧 Destroying Layer 2.5 (Add-ons: Karpenter, KEDA)..."
cd 02.5-addons && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 4. Layer 2: Cluster (EKS) & OIDC Cleanup
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 2 (Cluster)..."
cd 02-cluster 

# 클러스터 삭제 전 OIDC ID 미리 확보 (삭제 후에는 확인 불가)
OIDC_URL=$(aws eks describe-cluster --name terraform-k8s-cluster --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || echo "")
OIDC_ID=$(echo $OIDC_URL | awk -F/ '{print $NF}')

terraform destroy -auto-approve

# [추가] 좀비 OIDC Provider 삭제 로직
if [ -n "$OIDC_ID" ]; then
  echo "🔎 Checking for leftover OIDC Provider: $OIDC_ID"
  OIDC_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ID')].Arn" --output text)
  
  if [ -n "$OIDC_ARN" ]; then
    echo "🧟 Zombie OIDC found. Deleting $OIDC_ARN..."
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
    echo "✅ OIDC Provider cleaned up."
  fi
fi
cd ..

# --------------------------------------
# 5. Layer 1: Network (비용 절감 모드)
# --------------------------------------
echo "--------------------------------------"
echo "💸 Saving Cost: Layer 1 (Turning off NAT & Bastion)..."
cd 01-network 
# 변수를 false로 덮어씌워 NAT/Bastion만 삭제 (VPC/EFS/S3는 유지)
terraform apply -var 'enable_nat_bastion=false' -auto-approve
cd ..

echo "✅ [Complete] 모든 리소스가 안전하게 삭제되었습니다. (비용 절감 모드 전환 완료)"