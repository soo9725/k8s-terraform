#!/bin/bash
# 주의: destroy 스크립트에서는 특정 리소스가 이미 없어서 발생하는 에러를 
# 무시하고 다음 삭제를 진행해야 하므로 set -e를 신중하게 다뤄야 합니다.
set -e

echo "🚨 [Start] 전체 인프라 삭제를 시작합니다..."

# --------------------------------------
# [NEW] GitHub Actions 가상 머신을 위한 Kubeconfig 업데이트
# --------------------------------------
echo "--------------------------------------"
echo "🔐 Fetching Kubeconfig for Actions Runner..."
# 클러스터가 이미 없어진 상태일 수도 있으므로, 실패해도 스크립트가 죽지 않게 || true 처리
aws eks update-kubeconfig --region ap-northeast-1 --name terraform-k8s-cluster --alias k8s-demo 2>/dev/null || echo "⚠️ Cluster not found or unreachable. Skipping kubectl cleanups."

# --------------------------------------
# 0. K8s 리소스 정리 (좀비 리소스 방지)
# --------------------------------------
# set +e를 선언하여 아래 kubectl 명령어들이 실패하더라도 스크립트가 멈추지 않고 
# 최후의 보루인 Terraform Destroy까지 무조건 도달하도록 강제합니다.
set +e

echo "--------------------------------------"
echo "🧹 Cleaning up Kubernetes Resources (To prevent Zombie ALB & Nodes)..."

echo "   - Disabling ArgoCD Auto-Sync..."
kubectl get applications -n argocd -o name 2>/dev/null | xargs -I {} kubectl patch {} -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true

echo "   - 🔓 Unlocking Finalizers for all critical CRDs (Dynamic Scan)..."
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
  CRD_LIST=$(kubectl api-resources --api-group="$group" -o name 2>/dev/null || true)
  if [ -z "$CRD_LIST" ]; then
    continue
  fi
  for crd in $CRD_LIST; do
    echo "       -> Unlocking $crd..."
    kubectl get "$crd" -A -o name 2>/dev/null | xargs -I {} kubectl patch {} --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
done

echo "   - Deleting Kafka Resources..."
kubectl delete kafka --all -n kafka --ignore-not-found=true --timeout=30s 2>/dev/null || true

echo "   - Deleting KEDA Resources..."
if [ -f "05-app/kedaconfig.yml" ]; then
  kubectl delete -f 05-app/kedaconfig.yml --ignore-not-found=true 2>/dev/null || true
fi
kubectl delete scaledobject --all -A --ignore-not-found=true 2>/dev/null || true
kubectl delete triggerauthentication --all -A --ignore-not-found=true 2>/dev/null || true

echo "   - Deleting Karpenter Resources..."
kubectl delete nodeclaims --all --timeout=60s 2>/dev/null || true

echo "⏳ Waiting for K8s API to stabilize (10s)..."
sleep 10

echo "   - Deleting ArgoCD Applications..."
kubectl delete application app -n argocd --ignore-not-found --wait=true 2>/dev/null || kubectl patch application app -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true

echo "   - Deleting Ingress Resources..."
kubectl delete -f 05-app/ingress.yml --ignore-not-found 2>/dev/null || true
kubectl delete ingress -A --all --ignore-not-found 2>/dev/null || true

# -------------------------------------------------------------------
# [추가 보완] EBS 볼륨 및 LoadBalancer 서비스 강제 정리 (좀비 차단)
# -------------------------------------------------------------------
echo "   - Deleting ALL PersistentVolumeClaims (To prevent orphaned EBS volumes)..."
kubectl delete pvc -A --all --ignore-not-found --timeout=30s 2>/dev/null || true

echo "   - Deleting ALL Services of type LoadBalancer (To prevent orphaned NLB/ELB)..."
kubectl get svc -A -o wide 2>/dev/null | grep LoadBalancer | awk '{print $1, $2}' | xargs -n 2 sh -c 'kubectl delete svc $1 -n $0 --ignore-not-found 2>/dev/null || true'

echo "⏳ Giving AWS a moment to detach ENIs and Volumes (15s)..."
sleep 15
# -------------------------------------------------------------------

# 이제 다시 안전장치(set -e)를 켜서 Terraform 구문에서 치명적 에러 발생 시 중단되도록 합니다.
set -e

echo "⏳ Verifying ALB deletion..."
for i in {1..30}; do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region ap-northeast-1 --query "LoadBalancers[?contains(DNSName, 'k8s')].LoadBalancerArn" --output text 2>/dev/null | wc -w)
  if [ "$ALB_COUNT" -eq 0 ]; then
    echo "✅ No ALBs found. Safe to proceed."
    break
  fi
  echo "⚠️ $ALB_COUNT ALB(s) still exist. Waiting 10s... ($i/30)"
  sleep 10
done

# --------------------------------------
# 1. Layer 6: Monitoring (Terraform Destroy)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 6 (Monitoring)..."
if [ -d "06-monitoring" ] && [ -f "06-monitoring/main.tf" ]; then
  cd 06-monitoring && terraform init && terraform destroy -auto-approve && cd ..
else
  echo "⚠️ 06-monitoring directory or Terraform files not found, skipping..."
fi

# --------------------------------------
# 2. Layer 5: Application (Terraform Destroy)
# --------------------------------------
# [FIX] 05-app에 테라폼 파일(.tf)이 없으면 init을 시도하지 않고 건너뜁니다.
echo "--------------------------------------"
echo "🗑️ Destroying Layer 5 (App)..."
if [ -d "05-app" ] && ls 05-app/*.tf 1> /dev/null 2>&1; then
  cd 05-app && terraform init && terraform destroy -auto-approve && cd ..
else
  echo "⚠️ 05-app directory has no Terraform files. Skipping Terraform destroy for Layer 5."
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

# OIDC Cleanup Logic (리전 명시)
OIDC_URL=$(aws eks describe-cluster --region ap-northeast-1 --name terraform-k8s-cluster --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || echo "")
OIDC_ID=$(echo $OIDC_URL | awk -F/ '{print $NF}')

terraform destroy -auto-approve

if [ -n "$OIDC_ID" ]; then
  echo "🔎 Checking for leftover OIDC Provider: $OIDC_ID"
  OIDC_ARN=$(aws iam list-open-id-connect-providers --region ap-northeast-1 --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ID')].Arn" --output text)
  if [ -n "$OIDC_ARN" ] && [ "$OIDC_ARN" != "None" ]; then
    echo "🧟 Zombie OIDC found. Deleting $OIDC_ARN..."
    aws iam delete-open-id-connect-provider --region ap-northeast-1 --open-id-connect-provider-arn "$OIDC_ARN"
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