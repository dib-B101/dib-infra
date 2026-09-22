# 배포 당일 순서 (2026-09-21 기준)

AWS 콘솔 로그인 후 **이 문서만 위에서 아래로** 따라가면 백엔드·AI·관리자 웹이 전부 뜬다.
자세한 설명은 [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md), 명령어만 필요하면 [RUNBOOK.md](RUNBOOK.md).

배포 대상은 셋이다. 안드로이드 앱은 AWS 에 올라가는 물건이 아니라 **ALB 주소로 다시 빌드**하는 것이다.

| 컴포넌트 | 어디에 | 주소 |
|---|---|---|
| 백엔드 (Spring) | EKS Deployment ×2 | `http://<ALB>/` |
| AI (FastAPI) | EKS Deployment ×1 | 클러스터 내부 전용 `http://dib-ai:8000` |
| 관리자 웹 (nginx) | EKS Deployment ×1 | `http://<ALB>/admin/` |
| 안드로이드 앱 | 기기에 설치 | ALB 주소를 넣고 재빌드 |

---

## ★ 전날 미리 해 둘 것

### AWS 계정이 있으면 (당일 25분 절약)

ECR 은 상시 스택이라 클러스터가 없어도 이미지를 밀어 넣을 수 있다.
**AI 이미지가 3GB 라 첫 푸시가 20~30분 걸린다.** 미리 밀어 두자.

```powershell
cd components\infra\infra\persistent
terraform init
terraform apply          # ECR 레포 3개(backend·ai·admin-web) + S3 + 수명주기 규칙

cd ..\..
.\scripts\build-push.ps1 # 세 이미지 빌드 후 ECR 푸시
```

> 이 단계는 **과금이 거의 없다**(ECR 저장 + S3). 클러스터를 안 띄우므로 안전하다.

### AWS 계정이 아직 없으면 — 빌드만 미리

`terraform output` 도 ECR 로그인도 자격증명이 필요해서 위 단계는 못 한다.
대신 **빌드만** 돌려 도커 레이어 캐시를 데워 둘 수 있다. 당일엔 푸시만 남는다.

```powershell
cd components\infra
.\scripts\build-push.ps1 -BuildOnly
```

레이어 캐시는 태그가 아니라 내용 기준이라, 당일 진짜 ECR 태그로 다시 빌드해도 캐시가 그대로 맞는다.
덤으로 **당일 쓸 빌드 명령이 실제로 통과하는지**를 미리 확인하는 효과가 있다.

---

### 외부 키를 파일로 준비해 둔다

`bootstrap.ps1` 이 홈 디렉터리 파일에서 읽는 값이다. 없으면 `REPLACE-` 로 비워 두고 나중에 patch 한다.

```powershell
Set-Content $HOME\.dib-db-pass "<RDS 비밀번호>"      # 이미 있으면 그대로
Set-Content $HOME\.dib-gms-key "<GMS API 키>"        # 상품 검수 2차 모델. 로컬 .env 의 GMS_API_KEY 와 같은 값
```

---

## 당일 1. 임시 스택 생성 (~20분) 💰 과금 시작

```powershell
cd components\infra\infra\ephemeral

# DB 비밀번호 (파일이 이미 있으면 재사용)
$env:TF_VAR_db_password = Get-Content $HOME\.dib-db-pass

terraform init
terraform apply          # Plan 확인 후 yes
```

노드는 **t3.large** 다. AI 가 같은 클러스터에 올라가서 t3.medium(4GB)으로는
백엔드 2대 + Kafka + AI 가 같이 안 들어간다. AI 를 빼면 `-var node_instance_type=t3.medium` 으로 낮춰도 된다.

## 당일 2. 클러스터 연결 + 부트스트랩 (~5분)

```powershell
aws eks update-kubeconfig --region ap-northeast-2 --name dib-eks
cd ..\..
.\scripts\bootstrap.ps1
```

`bootstrap.ps1` 이 하는 일:
- ALB 컨트롤러 + metrics-server 설치
- `dib-secrets` 생성 (DB·Redis·Kafka 주소, JWT·HMAC 키 자동 생성, AI 용 `DIB_DATABASE_URL` 포함)
- `dib-ai-secrets` 생성 (GMS 검수 모델 키·주소·모델명 — AI Pod 만 읽는다)
- ServiceAccount `dib-backend` 에 S3 접근 IRSA 부착

**출력되는 `DIB_SERVICE_HMAC_SECRET` / `DIB_AI_HMAC_SECRET` 두 값을 적어 둔다** — AI 와 백엔드가
같은 값을 써야 해서 지금은 같은 Secret 에서 양쪽에 주입되지만, 외부 AI 로 바꿀 때 필요하다.

## 당일 3. 배포 (~8분)

```powershell
.\scripts\deploy.ps1
```

순서: Kafka → AI → 백엔드 → 관리자웹 → Ingress(ALB) → HPA.
매니페스트의 `__ECR__` 는 스크립트가 `terraform output ecr_registry` 로 치환한다 —
**계정 번호를 손으로 고칠 필요가 없다.**

스크립트가 시작할 때 ECR 에 `latest` 세 개가 있는지 먼저 확인한다. 없으면 즉시 멈춘다
(예전엔 없는 이미지로 Pod 가 ImagePullBackOff 로 몇 분을 버티다 죽었다).

끝나면 ALB 주소와 안드로이드 빌드 명령을 찍어 준다.

## 당일 4. 외부 서비스 키 채우기 (쓸 거면)

bootstrap 이 `REPLACE-` 로 비워 둔 값들이다. **안 채워도 서버는 뜬다** — 해당 기능만 실패한다.

| 키 | 비었을 때 |
|---|---|
| `TOSS_SECRET_KEY` | 낙찰 자동결제 실패 (주문은 PENDING 유지, 구매자 재시도 가능) |
| `KAKAO_CLIENT_ID`, `KAKAO_REDIRECT_URIS` | 카카오 로그인만 `KAKAO_AUTH_FAILED` |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | 라이브 방송 시작(송출 토큰)만 `STREAM_UNAVAILABLE` |

```powershell
kubectl patch secret dib-secrets --type merge -p '{"stringData":{"TOSS_SECRET_KEY":"<토스 키>","LIVEKIT_URL":"wss://<...>.livekit.cloud","LIVEKIT_API_KEY":"<키>","LIVEKIT_API_SECRET":"<시크릿>"}}'
kubectl rollout restart deployment/dib-backend
```

`KAKAO_REDIRECT_URIS` 는 앱 빌드에 넣는 `DIB_KAKAO_REDIRECT_URI` 와 **글자 그대로** 같아야 한다.

## 당일 5. 안드로이드 앱 재빌드

ALB 주소를 넣어 빌드해야 앱이 배포된 서버를 본다.

```powershell
cd ..\..\frontend
.\gradlew installDebug -PDIB_API_BASE_URL=http://<ALB> -PDIB_WS_URL=ws://<ALB>/ws
```

`installDebug` 빌드는 `app\src\debug\res\xml\network_security_config.xml` 이 평문(http)을 전면 허용하므로
ALB 주소를 어디에 적을 필요가 없다. **release 빌드**는 main 설정(https 전용)을 그대로 쓰기 때문에
http ALB 에 붙일 수 없다 — 시연은 debug 빌드로 한다.

문자·메일은 발송 업체가 없어 운영에서도 **로그로만** 남는다. 회원가입 인증번호는
`kubectl logs deploy/dib-backend | Select-String "SMS 발송"` 으로 확인한다.

## 당일 6. 확인

```powershell
kubectl get pods -o wide                       # 전부 Running
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl.exe http://$ALB/actuator/health           # {"status":"UP"}
curl.exe http://$ALB/admin/ -I                 # 200
kubectl logs deploy/dib-ai --tail=20           # 모델 로딩 완료 확인
```

---

## 끝나면 반드시 철거 💰

```powershell
cd components\infra
.\scripts\teardown.ps1
```

Ingress 를 먼저 지워 ALB 를 없앤 뒤 terraform destroy 한다. **순서를 어기면 ALB 가 VPC 를 물고 있어
destroy 가 실패하고 잔해가 과금된다.** ECR·S3(상시 스택)는 남는 게 정상이다.

---

## 걸릴 만한 것

| 증상 | 원인 / 대처 |
|---|---|
| Pod `ImagePullBackOff` | ECR 에 이미지가 없다. `build-push.ps1` 먼저 |
| Pod `exec format error` | ARM 에서 빌드했다. `build-push.ps1` 은 `--platform linux/amd64` 를 항상 붙인다 |
| 백엔드 `CrashLoopBackOff`, 로그에 `Could not resolve placeholder` | `dib-secrets` 에 값이 빠졌다. bootstrap 을 다시 |
| 백엔드 로그에 `applied migration not resolved locally` | 이미지가 DB 보다 낡았다. **이미지를 다시 빌드·푸시**하고 rollout restart |
| AI Pod 가 `Pending` | 노드 메모리 부족. `kubectl describe pod` 로 확인, 노드 타입이 t3.large 인지 |
| ALB 주소가 안 나옴 | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| `/admin/` 은 되는데 화면이 빈다 | 에셋 경로 문제. vite `base: '/admin/'` 과 nginx `location /admin/` 이 짝이다 |
| 앱이 "네트워크 연결을 확인해주세요" | release 빌드로 http ALB 에 붙였다 (평문 차단). debug 빌드를 쓴다 |
| 등록한 상품이 전부 "검토 필요" 로 보류 | `dib-ai-secrets` 의 `GEMINI_API_KEY` 가 비었다. 채우고 `kubectl rollout restart deployment/dib-ai` |
| 백엔드 `CrashLoopBackOff`, 로그에 `SmsSender` 빈 없음 | 옛 이미지다. 발송 구현체가 `@Profile("local")` 이던 시절 — 이미지를 다시 빌드·푸시 |
