# bootstrap.ps1 — 클러스터 생성(terraform apply) 후 1회 실행
# ALB 컨트롤러 + metrics-server + 접속정보 Secret
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..\infra\ephemeral

$LB_ROLE  = terraform output -raw lb_role_arn
$VPC_ID   = terraform output -raw vpc_id
$RDS      = terraform output -raw rds_endpoint
$REDIS    = terraform output -raw redis_endpoint
$APP_ROLE = terraform output -raw app_role_arn     # 백엔드 Pod 의 S3 접근용 IRSA
$DB_PASS  = Get-Content $HOME\.dib-db-pass

# 상품 이미지 버킷은 persistent 스택 소유 (클러스터를 부숴도 이미지는 남는다)
Push-Location $PSScriptRoot\..\infra\persistent
$S3_BUCKET = terraform output -raw s3_bucket
Pop-Location

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
#    application.yaml 이 기본값 없이 요구하는 값(PHONE_VERIFICATION_HMAC_SECRET)이 여기 빠지면
#    플레이스홀더 해석에 실패해 컨텍스트가 아예 안 뜬다 → CrashLoopBackOff. 추가 전 반드시 확인.
function New-Secret { -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 48 | ForEach-Object {[char]$_}) }

$SERVICE_HMAC = New-Secret   # 백엔드 -> AI 요청 서명. AI 서버와 같은 값이어야 한다
$AI_HMAC      = New-Secret   # AI -> 백엔드 콜백 서명. AI 서버와 같은 값이어야 하고 위와는 달라야 한다

kubectl delete secret dib-secrets --ignore-not-found
kubectl create secret generic dib-secrets `
  --from-literal=DB_URL="jdbc:postgresql://${RDS}:5432/auction" `
  --from-literal=DB_PASSWORD="$DB_PASS" `
  --from-literal=REDIS_HOST="$REDIS" `
  --from-literal=KAFKA_SERVERS="kafka-0.kafka:9092" `
  --from-literal=DIB_DATABASE_URL="postgresql://auction:${DB_PASS}@${RDS}:5432/auction" `
  --from-literal=DIB_EMBED_DATABASE_URL="postgresql://auction:${DB_PASS}@${RDS}:5432/auction" `
  --from-literal=JWT_SECRET="$(New-Secret)" `
  --from-literal=PHONE_VERIFICATION_HMAC_SECRET="$(New-Secret)" `
  --from-literal=DIB_SERVICE_HMAC_SECRET="$SERVICE_HMAC" `
  --from-literal=DIB_AI_HMAC_SECRET="$AI_HMAC" `
  --from-literal=TOSS_SECRET_KEY="REPLACE-toss-secret-key" `
  --from-literal=DIB_S3_BUCKET="$S3_BUCKET" `
  --from-literal=AWS_REGION="ap-northeast-2" `
  --from-literal=DIB_AI_ENABLED="false" `
  --from-literal=DIB_AI_BASE_URL="http://dib-ai:8000" `
  --from-literal=DIB_AI_CALLBACK_BASE_URL="http://dib-backend" `
  --from-literal=KAKAO_CLIENT_ID="REPLACE-kakao-rest-api-key" `
  --from-literal=KAKAO_CLIENT_SECRET="" `
  --from-literal=KAKAO_REDIRECT_URIS="REPLACE-app-redirect-uri" `
  --from-literal=LIVEKIT_URL="REPLACE-wss-livekit-url" `
  --from-literal=LIVEKIT_API_KEY="REPLACE-livekit-api-key" `
  --from-literal=LIVEKIT_API_SECRET="REPLACE-livekit-api-secret"

# 3-1. AI 전용 Secret — 상품 검수 2차 모델(GMS 게이트웨이 → Gemini) 키.
#      ai.yaml 만 이 Secret 을 읽는다(optional). 키는 DB 비밀번호처럼 홈 디렉터리 파일에서 읽는다:
#        Set-Content $HOME\.dib-gms-key "<GMS API 키>"
#      파일이 없으면 REPLACE 로 만들어 두고 나중에 patch 로 채운다. 비어 있어도 AI 는 뜨지만
#      2차 검수를 못 하니 상품이 전부 관리자 보류 큐로 간다. 값 이름은 로컬 compose(.env) 와 같다
$GMS_KEY = if (Test-Path $HOME\.dib-gms-key) { (Get-Content $HOME\.dib-gms-key -Raw).Trim() } else { "REPLACE-gms-api-key" }
kubectl delete secret dib-ai-secrets --ignore-not-found
kubectl create secret generic dib-ai-secrets `
  --from-literal=MODERATION_PROVIDER="gemini" `
  --from-literal=MODERATION_MODEL="gemini-2.5-flash-lite" `
  --from-literal=GEMINI_BASE_URL="https://gms.ssafy.io/gmsapi/generativelanguage.googleapis.com/v1beta" `
  --from-literal=GEMINI_API_KEY="$GMS_KEY"
if ($GMS_KEY -like "REPLACE-*") {
    Write-Host "GMS 키 파일($HOME\.dib-gms-key)이 없어 GEMINI_API_KEY 를 비워 뒀습니다. 채운 뒤 kubectl rollout restart deployment/dib-ai" -ForegroundColor Yellow
}

# 4. 백엔드 ServiceAccount — 상품 이미지 S3 접근 권한(IRSA)
#    spring.yaml 의 Pod 가 이 SA 로 뜬다. 키를 Secret 에 넣지 않고 역할로 받는다.
kubectl create serviceaccount dib-backend --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount dib-backend "eks.amazonaws.com/role-arn=$APP_ROLE" --overwrite

Write-Host "`n===== AI 서버 담당자에게 전달할 값 =====" -ForegroundColor Cyan
Write-Host "DIB_SERVICE_HMAC_SECRET = $SERVICE_HMAC"
Write-Host "DIB_AI_HMAC_SECRET      = $AI_HMAC"
Write-Host "두 값이 양쪽에서 같아야 요청/콜백 서명이 통과한다.`n" -ForegroundColor Cyan

Write-Host "AI 주소는 클러스터 내부 Service 라 이미 채워져 있고, DIB_AI_ENABLED 는 deploy.ps1 이 true 로 바꾼다." -ForegroundColor Yellow
Write-Host "문자·메일은 발송 업체가 없어 운영에서도 로그로만 남는다. 인증번호는 kubectl logs deploy/dib-backend | Select-String 'SMS 발송' 으로 본다." -ForegroundColor Yellow
Write-Host "REPLACE- 로 남은 값(TOSS_SECRET_KEY, KAKAO_*, LIVEKIT_*, dib-ai-secrets 의 GEMINI_API_KEY)은 아래처럼 덮는다. LIVEKIT_* 이 비면 라이브 방송 시작만 실패하고 나머지는 정상." -ForegroundColor Yellow
Write-Host "  KAKAO_REDIRECT_URIS 는 앱 빌드의 DIB_KAKAO_REDIRECT_URI 와 글자 그대로 같아야 한다(쉼표로 여러 개). 안 맞으면 INVALID_KAKAO_REDIRECT_URI." -ForegroundColor Yellow
Write-Host '  kubectl patch secret dib-secrets --type merge -p "{\"stringData\":{\"TOSS_SECRET_KEY\":\"<값>\"}}"'
Write-Host '  kubectl rollout restart deployment/dib-backend'
Write-Host "(kubectl edit 은 base64 값을 직접 넣어야 해서 실수가 잦다)" -ForegroundColor Yellow

Write-Host "`n부트스트랩 완료. 다음: scripts\deploy.ps1" -ForegroundColor Green
