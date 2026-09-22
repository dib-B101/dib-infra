# build-push.ps1 — 세 이미지를 빌드해서 ECR 로 밀어 넣는다 (backend / ai / admin-web)
#
# ECR 은 상시(persistent) 스택이라 클러스터가 없어도 푸시할 수 있다.
# ★ 시연 전날 미리 한 번 돌려 두면 당일엔 terraform + deploy 만 하면 된다.
#   AI 이미지는 torch·transformers 때문에 수 GB 라 첫 푸시가 10~20분 걸린다.
#
# 사용:
#   .\scripts\build-push.ps1                 # 셋 다
#   .\scripts\build-push.ps1 -Only backend   # 하나만
param(
    [ValidateSet("all", "backend", "ai", "admin-web")]
    [string]$Only = "all",
    [string]$Tag = "latest",
    [string]$Region = "ap-northeast-2",
    # AWS 계정 없이 빌드만 돌려 레이어 캐시를 데워 둔다. ECR 로그인·푸시를 건너뛴다.
    # 전날 이걸 돌려 두면 당일엔 캐시가 맞아서 빌드가 거의 즉시 끝나고 푸시만 남는다
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

# 컴포넌트 소스는 orchestration 레포 아래에 서브모듈로 있다.
# 이 스크립트는 components/infra/scripts/ 에 있으므로 세 단계 올라가야 orchestration 루트다
# (두 단계만 올라가면 components/ 에서 components/components 를 찾다가 죽는다)
$ROOT = Resolve-Path "$PSScriptRoot\..\..\.."
$COMPONENTS = Join-Path $ROOT "components"
if (-not (Test-Path (Join-Path $COMPONENTS "backend"))) {
    throw "components/ 를 못 찾았습니다. infra 레포가 dib-orchestration 아래 서브모듈로 있어야 합니다: $COMPONENTS"
}

if ($BuildOnly) {
    # ECR 주소를 모르니 로컬 태그로 빌드한다. 도커 레이어 캐시는 태그가 아니라 내용 기준이라
    # 당일 진짜 태그로 다시 빌드해도 캐시가 그대로 맞는다
    $ECR = "local"
    Write-Host "BuildOnly — ECR 로그인·푸시를 건너뜁니다 (캐시 예열용)" -ForegroundColor Cyan
} else {
    Push-Location "$PSScriptRoot\..\infra\persistent"
    $ECR = terraform output -raw ecr_registry
    Pop-Location
    if (-not $ECR) { throw "ecr_registry output 이 비었습니다. infra/persistent 에서 terraform apply 를 먼저 하세요." }
    Write-Host "ECR: $ECR" -ForegroundColor Cyan

    aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $ECR
    if ($LASTEXITCODE -ne 0) { throw "ECR 로그인 실패 — aws configure 를 확인하세요" }
}

# EKS 노드가 amd64 다. Apple Silicon 이나 ARM 윈도우에서 그냥 빌드하면
# 노드에서 exec format error 로 Pod 가 안 뜬다. 최다 빈출 사고라 항상 명시한다
$PLATFORM = "linux/amd64"

function Build-Push($name, $context, [string[]]$buildArgs) {
    $image = "$ECR/dib-$name`:$Tag"
    Write-Host "`n===== $name 빌드 =====" -ForegroundColor Yellow
    $cmd = @("build", "--platform", $PLATFORM, "-t", $image)
    foreach ($a in $buildArgs) { $cmd += @("--build-arg", $a) }
    $cmd += $context
    & docker @cmd
    if ($LASTEXITCODE -ne 0) { throw "$name 빌드 실패" }

    if ($BuildOnly) {
        Write-Host "===== $name 빌드 완료 (푸시 건너뜀) =====" -ForegroundColor DarkGray
        return
    }
    Write-Host "===== $name 푸시 =====" -ForegroundColor Yellow
    docker push $image
    if ($LASTEXITCODE -ne 0) { throw "$name 푸시 실패" }
}

if ($Only -in @("all", "backend")) {
    Build-Push "backend" (Join-Path $COMPONENTS "backend") @()
}
if ($Only -in @("all", "ai")) {
    Build-Push "ai" (Join-Path $COMPONENTS "ai") @()
}
if ($Only -in @("all", "admin-web")) {
    # VITE_API_BASE_URL=/ 로 두면 같은 ALB(동일 출처)로 API 를 친다.
    # ALB 주소를 빌드에 박지 않으므로 이 이미지는 미리 만들어 둘 수 있다
    Build-Push "admin-web" (Join-Path $COMPONENTS "frontend\admin-web") @("VITE_API_BASE_URL=/")
}

if ($BuildOnly) {
    Write-Host "`n빌드 캐시 예열 완료. AWS 로그인 후 -BuildOnly 없이 다시 돌리면 푸시만 남습니다." -ForegroundColor Green
} else {
    Write-Host "`n푸시 완료. 다음: scripts\bootstrap.ps1 -> scripts\deploy.ps1" -ForegroundColor Green
}
