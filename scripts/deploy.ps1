# deploy.ps1 — Kafka -> AI -> Spring -> 관리자웹 -> Ingress(ALB 생성) -> HPA
#
# 매니페스트의 __ECR__ 를 terraform output 으로 치환해서 적용한다.
# 예전엔 spring.yaml 에 계정 번호가 박혀 있어서 계정이 다르면 손으로 고쳐야 했다.
#
# ALB 주소는 Ingress 를 만든 뒤에야 나온다. 그 주소에 의존하는 값
# (AI 가 백엔드로 콜백할 주소)은 마지막에 Secret 에 채우고 백엔드를 재시작한다.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

Push-Location infra\persistent
$ECR = terraform output -raw ecr_registry
Pop-Location
if (-not $ECR) { throw "ecr_registry output 이 비었습니다. infra/persistent 에서 terraform apply 를 먼저 하세요." }
Write-Host "ECR: $ECR" -ForegroundColor Cyan

# 이미지가 실제로 올라가 있는지 먼저 본다. 없으면 Pod 가 ImagePullBackOff 로 죽을 때까지
# 3~5분을 기다리게 되는데, 여기서 잡으면 즉시 안다
foreach ($repo in @("dib-backend", "dib-ai", "dib-admin-web")) {
    aws ecr describe-images --repository-name $repo --image-ids imageTag=latest --region ap-northeast-2 --output json > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ECR 에 ${repo}:latest 가 없습니다. 먼저 .\scripts\build-push.ps1 을 실행하세요."
    }
}

function Apply-Manifest($path) {
    Write-Host "apply $path" -ForegroundColor DarkGray
    (Get-Content $path -Raw) -replace '__ECR__', $ECR | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "$path 적용 실패" }
}

# 1. Kafka 먼저 (백엔드가 부팅 때 붙는다)
Apply-Manifest "infra\k8s\kafka.yaml"
kubectl rollout status statefulset/kafka --timeout=180s

# 2. AI — 모델 로딩이 길어서 백엔드보다 먼저 시작시켜 둔다.
#    백엔드는 AI 가 없어도 뜨므로(dib.ai.enabled) 완료를 기다리지 않는다
Apply-Manifest "infra\k8s\ai.yaml"

# 3. 백엔드
Apply-Manifest "infra\k8s\spring.yaml"
kubectl rollout status deployment/dib-backend --timeout=300s

# 4. 관리자 웹
Apply-Manifest "infra\k8s\admin-web.yaml"
kubectl rollout status deployment/dib-admin-web --timeout=180s

# 5. ALB (두 Ingress 가 group.name=dib 로 한 대를 공유한다)
Apply-Manifest "infra\k8s\ingress.yaml"
Apply-Manifest "infra\k8s\hpa.yaml"

Write-Host "`nALB 주소 발급 대기..." -ForegroundColor Yellow
$ALB = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 10
    $ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    if ($ALB) { break }
    Write-Host "  ... $([int](($i + 1) * 10))초" -ForegroundColor DarkGray
}
if (-not $ALB) { throw "ALB 주소를 못 받았습니다. kubectl logs -n kube-system deploy/aws-load-balancer-controller 를 보세요." }

# 6. ALB 주소가 나와야 채울 수 있는 값 — AI 가 결과를 돌려보낼 주소.
#    AI 는 클러스터 안에 있으므로 내부 Service 주소로 충분하고 외부 노출이 필요 없다.
#    상품 이미지도 AI 가 이 주소로 받아 간다
# JSON 은 작은따옴표 문자열로 넘긴다. 큰따옴표 안에서 백틱으로 이스케이프하면
# PowerShell 이 네이티브 명령에 넘길 때 따옴표가 깨지는 일이 잦다
# DIB_AI_MODERATION_ENABLED 까지 켜야 상품 등록이 AI 검수(GMS)를 거친다. AI_ENABLED 만 켜면 이상입찰·추천만 붙고
# 상품은 즉시 승인된다 — 로컬 compose 와 같은 조합으로 맞춘다
$aiPatch = '{"stringData":{"DIB_AI_CALLBACK_BASE_URL":"http://dib-backend","DIB_AI_BASE_URL":"http://dib-ai:8000","DIB_AI_ENABLED":"true","DIB_AI_MODERATION_ENABLED":"true"}}'
kubectl patch secret dib-secrets --type merge -p $aiPatch
if ($LASTEXITCODE -ne 0) { throw "dib-secrets 패치 실패" }
kubectl rollout restart deployment/dib-backend
kubectl rollout status deployment/dib-backend --timeout=300s

Write-Host "`n===== 배포 완료 =====" -ForegroundColor Green
Write-Host "API      : http://$ALB"
Write-Host "관리자웹 : http://$ALB/admin/"
Write-Host "헬스     : curl.exe http://$ALB/actuator/health"
Write-Host ""
Write-Host "안드로이드 앱은 이 주소로 다시 빌드해야 합니다:" -ForegroundColor Yellow
Write-Host "  cd components\frontend"
Write-Host "  .\gradlew installDebug -PDIB_API_BASE_URL=http://$ALB -PDIB_WS_URL=ws://$ALB/ws"   # STOMP 엔드포인트는 /ws 하나
Write-Host ""
Write-Host "아직 REPLACE 로 남은 시크릿(TOSS_SECRET_KEY 등)은 kubectl patch 로 채우세요." -ForegroundColor Yellow
