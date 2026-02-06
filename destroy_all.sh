#!/bin/bash

echo "🚨 [Start] 전체 인프라 삭제를 시작합니다..."

# 1. Layer 4: Ingress (ALB 삭제를 위해 가장 먼저!)
# (아직 안 만드셨으면 이 줄은 주석 처리하거나 빼세요)
# echo "--------------------------------------"
# echo "🗑️ Destroying Layer 4 (Ingress)..."
# cd 04-ingress && terraform destroy -auto-approve && cd ..

# 2. Layer 3: Registry & Apps
echo "--------------------------------------"
echo "🗑️ Destroying Layer 3 (Registry)..."
# 폴더명 03-registry 로 이동 -> 삭제 -> 상위 폴더로 복귀
cd 03-registry && terraform destroy -auto-approve && cd ..

# 3. Layer 2: Cluster (EKS)
echo "--------------------------------------"
echo "🗑️ Destroying Layer 2 (Cluster)..."
cd 02-cluster && terraform destroy -auto-approve && cd ..

#!/bin/bash

# ... (Layer 4, 3, 2 삭제 부분은 기존과 동일) ...

# 4. Layer 1: Network (비용 절감 모드로 전환)
echo "--------------------------------------"
echo "💸 Saving Cost: Layer 1 (Turning off NAT & Bastion)..."

# 폴더 이동
cd 01-network 

# [핵심] 변수 파일은 건드리지 않고, 명령어에서 변수값만 false로 덮어씌워서 적용
# -var 'enable_nat_bastion=false' : 이 옵션이 파일의 default = true를 이깁니다.
terraform apply -var 'enable_nat_bastion=false' -auto-approve

# 원래 폴더로 복귀
cd ..

echo "✅ [Complete] 인프라 삭제 및 비용 절감 설정이 완료되었습니다."