#!/bin/bash
set -e
echo "🚨 [Start] 전체 인프라 삭제를 시작합니다..."

# --------------------------------------
# 0. [중요] K8s 리소스 정리 (좀비 ALB 방지)
# --------------------------------------
echo "--------------------------------------"
echo "🧹 Cleaning up Kubernetes Resources (To prevent Zombie ALB)..."

# ArgoCD 앱 삭제 (파이널라이저 때문에 안 지워지는 경우 강제 삭제)
# 앱이 삭제되어야 연관된 LoadBalancer/Ingress가 정리됨
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
# 3. Layer 2: Cluster (EKS)
# --------------------------------------
echo "--------------------------------------"
echo "🗑️ Destroying Layer 2 (Cluster)..."
cd 02-cluster && terraform destroy -auto-approve && cd ..

# --------------------------------------
# 4. Layer 1: Network (비용 절감 모드)
# --------------------------------------
echo "--------------------------------------"
echo "💸 Saving Cost: Layer 1 (Turning off NAT & Bastion)..."
cd 01-network 
# 변수를 false로 덮어씌워 NAT/Bastion만 삭제 (VPC/EFS/S3는 유지)
terraform apply -var 'enable_nat_bastion=false' -auto-approve
cd ..

echo "✅ [Complete] 모든 리소스가 안전하게 삭제되었습니다. (비용 절감 모드 전환 완료)"