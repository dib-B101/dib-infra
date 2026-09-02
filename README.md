# dib-infra

경매 플랫폼 **DIB**의 전체 인프라를 Terraform으로 관리하는 저장소.
클러스터·DB·캐시를 포함한 전 스택을 **약 20분에 생성, 15분에 완전 삭제**한다.
평소 개발은 로컬 Docker Compose로 하고, AWS는 시연·부하테스트 때만 띄운다.

## 구조

| 경로 | 내용 | 수명 |
|---|---|---|
| `infra/persistent/` | ECR(이미지 저장소), S3(상품 이미지) | 상시 유지 — 월 $1 미만 |
| `infra/ephemeral/` | VPC(3계층 서브넷)·EKS·RDS Multi-AZ·Redis Replica | 시연 시에만 — 세션당 $4~5 |
| `infra/k8s/` | Kafka(StatefulSet), Spring(Deployment), Ingress(=ALB), HPA | 클러스터와 함께 |
| `scripts/` | bootstrap / deploy / teardown (PowerShell) | — |
| `load-test/` | k6 입찰 부하 시나리오 | — |
| `docs/` | A to Z 구축 가이드, 배포 설명서 | — |

## 처음이라면

**[docs/ATOZ_WINDOWS_GUIDE.md](docs/ATOZ_WINDOWS_GUIDE.md)** 를 1장부터.
AWS 계정 세팅 → 도구 설치 → 이 레포 코드로 스택 생성까지 전부 있다.

## 시연 날 (준비 끝난 사람용)

```powershell
# 띄우기 (~20분)
cd infra\ephemeral
$env:TF_VAR_db_password = Get-Content $HOME\.dib-db-pass
terraform apply -auto-approve

# 부트스트랩 + 배포 (~10분)
aws eks update-kubeconfig --name dib-eks --region ap-northeast-2
.\scripts\bootstrap.ps1
.\scripts\deploy.ps1     # 끝나면 ALB 주소 출력

# 철거 (끝나면 반드시!)
.\scripts\teardown.ps1
```

## ⚠️ 규칙 세 가지

1. **철거는 무조건 `scripts/teardown.ps1`로** — `terraform destroy` 직접 치면 ALB가 남아 과금된다 (Ingress를 먼저 지워야 함)
2. `*.tfstate`, `*.tfvars`, 비밀번호는 절대 커밋 금지 (.gitignore에 있음)
3. 스택 띄우고 내릴 때 이슈에 한 줄 기록 — 누가 언제 띄웠는지 추적용

## 시작 전 교체할 값 (2곳)

- `infra/persistent/main.tf`, `infra/ephemeral/main.tf` 의 state 버킷명 `dib-tfstate-b101a` — S3 버킷명은 전 세계 유일이라 겹치면 변경
- `infra/k8s/spring.yaml` 의 `<ACCOUNT_ID>` — AWS 계정 12자리

## Git 정책

이 저장소는 [`dib-orchestration`의 중앙 Git Flow 정책](https://github.com/dib-B101/dib-orchestration/blob/main/docs/GIT_FLOW.md)을 따릅니다.
