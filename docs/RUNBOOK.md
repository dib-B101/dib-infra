# DIB 인프라 런북 (실행 명령 모음)

> 인프라를 띄우고 · 확인하고 · 내리는 모든 명령. Windows PowerShell 기준.
> 원리 설명은 `ARCHITECTURE.md`, 처음 세팅은 `ATOZ_WINDOWS_GUIDE.md` 참고.

## 규칙 세 가지

1. 철거는 **반드시 `scripts\teardown.ps1`** — terraform destroy 직접 금지 (ALB 고아 과금)
2. 띄운 사람이 내린다 — 세션 시작/종료를 팀에 공유 (이슈 한 줄)
3. 💰 `terraform apply`부터 teardown까지 시간당 ~$0.7(절약) / ~$1.2(풀HA)

---

## A. 띄우기 (~20분) 💰 과금 시작

```powershell
cd C:\Users\SSAFY\Desktop\dev\dib\dib-orchestration\components\infra\infra\ephemeral

# DB 비밀번호 (파일이 이미 있으면 재사용)
$env:TF_VAR_db_password = Get-Content $HOME\.dib-db-pass
# 파일이 없을 때(최초 1회)만:
# $env:TF_VAR_db_password = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 24 | % {[char]$_})
# $env:TF_VAR_db_password | Out-File $HOME\.dib-db-pass

terraform apply -var="full_ha=false"    # 절약 모드 (평소 테스트)
# terraform apply                       # 풀 HA (발표 리허설·부하테스트)
# → Plan ~71 to add 확인 후 yes
```

## B. 클러스터 연결 + 부트스트랩 (~5분)

```powershell
aws eks update-kubeconfig --name dib-eks --region ap-northeast-2
kubectl get nodes -o wide               # 2대 Ready, AZ 2a/2c 분산 확인

cd C:\Users\SSAFY\Desktop\dev\dib\dib-orchestration\components\infra
.\scripts\bootstrap.ps1                 # ALB 컨트롤러 + metrics-server + Secret
kubectl get pods -n kube-system | Select-String "load-balancer"   # Running 2개
```

## C. 배포

```powershell
# C-1. 인프라만 검증할 때 (백엔드 이미지 불필요)
kubectl apply -f infra\k8s\smoke.yaml
kubectl get ingress smoke-ingress       # ADDRESS 뜰 때까지 2~3분 반복
curl.exe http://<ADDRESS>/              # "dib infra smoke ok" 면 성공

# C-2. 실제 백엔드 배포 (ECR에 dib-backend:latest 있을 때)
kubectl apply -f infra\k8s\kafka.yaml
kubectl rollout status statefulset/kafka --timeout=180s
kubectl apply -f infra\k8s\spring.yaml
kubectl rollout status deployment/auction-backend --timeout=300s
kubectl apply -f infra\k8s\ingress.yaml -f infra\k8s\hpa.yaml
kubectl get ingress auction-ingress     # 이 ADDRESS가 앱의 BASE_URL
curl.exe http://<ADDRESS>/actuator/health   # {"status":"UP"}
# ※ smoke와 동시 배포 금지 — smoke 먼저 지울 것: kubectl delete -f infra\k8s\smoke.yaml
```

## D. 상태 확인·디버깅

```powershell
kubectl get pods -o wide                          # Pod 상태·배치 노드
kubectl get hpa                                   # TARGETS 숫자면 정상, <unknown>이면 metrics-server
kubectl logs deploy/auction-backend --tail=100    # 앱 로그
kubectl logs deploy/auction-backend -f            # 실시간
kubectl describe pod <pod이름>                     # Pod가 안 뜰 때 (Events 섹션)
kubectl logs -n kube-system deploy/aws-load-balancer-controller   # ALB 안 생길 때
kubectl get events --sort-by=.lastTimestamp | Select-Object -Last 15
```

## E. 부하 테스트 (선택)

```powershell
$ALB = kubectl get ingress auction-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
$env:BASE_URL = "http://$ALB"; $env:TOKEN = "<로그인해서 받은 JWT>"
k6 run load-test\bid-scenario.js
# 다른 창: kubectl get hpa -w    ← Pod 2→6 늘어나는 장면 녹화 (포트폴리오)
```

## F. 철거 (~15분) 💰 과금 정지 — 세션 종료 시 필수

```powershell
cd C:\Users\SSAFY\Desktop\dev\dib\dib-orchestration\components\infra
.\scripts\teardown.ps1
# 마지막 "삭제 검증" 출력이 전부 빈 값([])인지 확인
# EKS / RDS / Redis / ALB / NAT / EC2 / EBS / EIP 전부 비어야 정산 끝
```

다음 날 콘솔 → Cost Explorer에서 그날 비용이 예상 범위($3 이하)인지 확인.

## G. 자주 터지는 문제

| 증상 | 조치 |
|---|---|
| bootstrap에서 webhook "no endpoints" | 컨트롤러 Pod Running 대기 후 metrics-server 재적용 (스크립트에 대기 로직 있음 — 구버전에서만 발생) |
| Ingress ADDRESS 계속 빈칸 | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` — 대부분 서브넷 태그/IRSA |
| Pod ImagePullBackOff | ECR에 이미지 없음 또는 태그 오타. `aws ecr describe-images --repository-name dib-backend` |
| Pod CrashLoopBackOff | `kubectl logs <pod>` — 대부분 actuator 누락 또는 환경변수 미참조 |
| HPA `<unknown>` | metrics-server 미설치 또는 Deployment resources.requests 누락 |
| Redis READONLY 에러 | Replica에 쓰기 시도 — Secret의 REDIS_HOST가 primary인지 |
| WebSocket 1분마다 끊김 | ingress.yaml의 idle_timeout=3600 annotation 확인 |
| destroy가 VPC에서 멈춤 | Ingress 안 지운 것 — 콘솔 EC2→로드밸런서에서 잔여 ALB 수동 삭제 후 teardown 재실행 |
| .ps1 실행 불가 | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| ALB 주소가 매번 바뀜 | 정상 — 매 배포 새 발급. 앱 BASE_URL 갈아끼우기 |
