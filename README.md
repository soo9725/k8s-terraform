## STEP 1. 환경 준비 및 비용 검토 (Cost & Setup)
[ ] AWS 계정 준비: $140 크레딧 확인 및 IAM Admin 계정 생성 (MFA 설정 필수).

[ ] 로컬 도구 설치: Terraform, AWS CLI, kubectl, helm.

[ ] Infracost 적용: Terraform 코드 작성 시 월 예상 비용 산출.

Check Point: NAT Gateway 토글 기능 적용 시 비용 절감 효과 시뮬레이션.

## STEP 2. Terraform 인프라 구축 (IaC) - Layered Architecture
[ ] Layer 1 - 네트워크 & 스토리지 (Permanent / 영구 계층)

기본 네트워크: VPC, Public/Private Subnet, IGW.

비용 절감 자동화 (Toggle):

NAT Gateway & EIP: 업무 시간 외 삭제 (GitHub Actions 연동).

Bastion Host: 업무 시간 외 삭제, 부팅 시 kubectl 자동 설치.

영구 스토리지 (Persistence):

EFS: Jenkins 설정, ArgoCD설정 저장. 및 CI/CD 아티팩트 저장용 (Layer 2가 삭제되어도 데이터 보존).

S3: Harbor 이미지 저장용 및 Terraform State 백엔드

[ ] Layer 2 - 컴퓨팅 클러스터 (Ephemeral / 임시 계층)

수명 주기: GitHub Actions를 통해 매일 생성 및 삭제.

EKS Cluster: v1.30 (안정 버전).

Managed Node Group: 시스템 파드용 최소 사양 (t3.medium or m7i-flex).

Terraform Helm Provider: 클러스터 생성 직후 필수 앱(ArgoCD/Jenkins, Karpenter등) 자동 설치 코드화.

## STEP 3. CI/CD 및 레지스트리, GitOps 구축 (Hybrid Infrastructure)
[ ] Harbor (Private Registry):

Layer 1의 S3를 스토리지로 연결 (이미지 영구 보존).

[ ] Jenkins (CI - 빌드 담당):

Layer 1의 EFS 마운트 (파이프라인 설정 보존).

Terraform ClusterRoleBinding으로 부팅 즉시 kubectl 권한 획득.

[ ] ArgoCD (CD - 배포 담당) [NEW]:

GitOps 구현: K8s Manifest 변경 사항을 감지하여 자동 배포.

선언적 설정 (Declarative): Terraform 설치 시 Git Repo URL 및 Credential 주입 (자동 연결).

[ ] ACK (App-Centric Infra):

애플리케이션용 SQS/DynamoDB를 K8s YAML로 생성하는 시연.

## STEP 4. 서비스 배포 및 네트워크 보안
[ ] Ingress Controller: AWS Load Balancer Controller(ALB) 설치.

[ ] DNS 자동화: ExternalDNS + Route53 (Layer 2 생성 시 도메인 자동 연결).

[ ] HTTPS: Cert-Manager (Let's Encrypt).

## STEP 5. 모니터링 및 알람 (Observability)
[ ] Prometheus & Grafana: 모니터링 대시보드 구축 (설정값은 ConfigMap으로 관리하여 재부팅 시 자동 복구).

[ ] Loki: 로그 수집.

[ ] Slack 연동: Alertmanager (장애 알람) 및 BotKube (채팅으로 클러스터 제어).

## STEP 6. 오토스케일링 (Auto Scaling & FinOps)
[ ] Karpenter: 트래픽 폭주 시 Spot Instance 자동 프로비저닝.

[ ] KEDA: 이벤트(SQS 메시지 수 등) 기반 오토스케일링 테스트.

[ ] 부하 테스트: K6를 이용해 대량 트래픽 발생 후 Karpenter의 대응 시연.
