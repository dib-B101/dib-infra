# bootstrap.ps1 — 클러스터 생성(terraform apply) 후 1회 실행
# ALB 컨트롤러 + metrics-server + 접속정보 Secret
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..\infra\ephemeral

$LB_ROLE = terraform output -raw lb_role_arn
$VPC_ID  = terraform output -raw vpc_id
$RDS     = terraform output -raw rds_endpoint
$REDIS   = terraform output -raw redis_endpoint
$DB_PASS = Get-Content $HOME\.dib-db-pass

# 1. AWS Load Balancer Controller (Ingress -> 실제 ALB 생성 담당)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
  -n kube-system `
  --set clusterName=dib-eks `
  --set region=ap-northeast-2 `
  --set vpcId=$VPC_ID `
  --set serviceAccount.create=true `
  --set serviceAccount.name=aws-load-balancer-controller `
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LB_ROLE"


# 컨트롤러 Pod가 뜰 때까지 대기 (webhook 준비 전에 Service 만들면 실패함)
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

# 2. metrics-server (HPA의 눈)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 3. 접속 정보 Secret
kubectl delete secret dib-secrets --ignore-not-found
kubectl create secret generic dib-secrets `
  --from-literal=DB_URL="jdbc:postgresql://${RDS}:5432/auction" `
  --from-literal=DB_PASSWORD="$DB_PASS" `
  --from-literal=REDIS_HOST="$REDIS" `
  --from-literal=KAFKA_SERVERS="kafka-0.kafka:9092" `
  --from-literal=JWT_SECRET="$(-join ((65..90)+(97..122)+(48..57) | Get-Random -Count 48 | ForEach-Object {[char]$_}))" `
  --from-literal=AI_SERVER_URL="https://REPLACE-onprem-ai-address" `
  --from-literal=AI_API_KEY="REPLACE-shared-api-key"

Write-Host "`n부트스트랩 완료. 다음: scripts\deploy.ps1" -ForegroundColor Green
