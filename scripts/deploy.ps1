# deploy.ps1 — Kafka -> Spring -> Ingress(ALB 생성) -> HPA 순서 배포
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

kubectl apply -f infra\k8s\kafka.yaml
kubectl rollout status statefulset/kafka --timeout=180s

kubectl apply -f infra\k8s\spring.yaml
kubectl rollout status deployment/dib-backend --timeout=300s

kubectl apply -f infra\k8s\ingress.yaml
kubectl apply -f infra\k8s\hpa.yaml

Write-Host "`nALB 주소 발급 대기 (2~3분)..." -ForegroundColor Yellow
Start-Sleep -Seconds 150
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Write-Host "`n===== API 주소: http://$ALB =====" -ForegroundColor Green
Write-Host "확인: curl.exe http://$ALB/actuator/health"
Write-Host "이 주소를 Kotlin 앱의 BASE_URL에 넣고 빌드하세요"
