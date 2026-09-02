# DIB 인프라 아키텍처 상세

> 이 문서 하나로 DIB의 인프라 전체를 이해할 수 있도록 쓴 표준 문서.
> 사람이든 AI든, 이 레포를 처음 보는 누구든 이것부터 읽는다.

## 1. 프로젝트 컨텍스트

**DIB**는 실시간 경매 플랫폼이다 (SSAFY B101 팀).
경매 도메인은 세 가지 문제를 동시에 풀어야 한다:

1. **동시성** — 같은 상품에 동시에 몰리는 입찰의 직렬화
2. **실시간성** — 모든 참여자 화면에 현재가 즉시 반영
3. **순간 부하** — 경매 마감 직전 트래픽 폭증

저장소 구조는 하네스(dib-orchestration) + 서브모듈 4개다:

```
dib-orchestration/            # 하네스 (전체 묶음, 문서, Git Flow 정책)
└─ components/
   ├─ frontend/               # Native Kotlin 앱 (Retrofit/OkHttp, WebSocket, Coroutines)
   ├─ backend/                # Spring Boot (CQRS-lite, WebSocket, JPA/MyBatis)
   ├─ ai/                     # FastAPI 온프레미스 AI 서버
   └─ infra/                  # ← 이 레포. Terraform + K8s 매니페스트 + 스크립트
```

## 2. 운영 전략: "평소엔 로컬, 필요할 때만 클라우드"

인프라는 두 스택으로 분리되어 있고, 이 분리가 이 레포의 뼈대다.

| 스택 | 위치 | 내용 | 수명 | 비용 |
|---|---|---|---|---|
| persistent | `infra/persistent/` | ECR(이미지 저장소), S3(상품 이미지) | 상시 유지 | 월 $1 미만 |
| ephemeral | `infra/ephemeral/` | VPC, EKS, RDS, Redis 등 전부 | 시연·테스트 때만 | 시간당 ~$0.7(절약)/~$1.2(풀HA) |

- 평소 개발은 로컬 Docker Compose(`docs/local-dev/`)에서 한다. AWS는 꺼져 있다.
- 시연·부하테스트 날만 `terraform apply`로 약 20분에 전체를 띄우고,
  끝나면 `scripts/teardown.ps1`로 15분에 완전 삭제한다.
- Terraform state는 S3 버킷 `dib-tfstate-b101a`에 스택별로 분리 보관된다.
- `full_ha` 변수 하나로 절약 모드(NAT 1, RDS/Redis 단일)와
  풀 HA(NAT 2, RDS Multi-AZ Standby, Redis Replica)를 전환한다.

## 3. 네트워크 레이아웃

리전 ap-northeast-2(서울), VPC `10.0.0.0/16`, AZ 2개(2a, 2c) × 계층 3개 = 서브넷 6개.

| 계층 | AZ-A | AZ-C | 배치 리소스 | 인터넷 노출 |
|---|---|---|---|---|
| Public | 10.0.1.0/24 | 10.0.2.0/24 | ALB, NAT Gateway | O (IGW 경유) |
| Private App | 10.0.11.0/24 | 10.0.12.0/24 | EKS 워커 노드(EC2) | X (나갈 때만 NAT) |
| Private Data | 10.0.21.0/24 | 10.0.22.0/24 | RDS, ElastiCache | X (노드 SG에서만 접근) |

- **들어오는 길은 ALB 하나뿐**이다. 노드·DB·Redis는 공인 IP가 없다.
- 나가는 길(외부 API, ECR pull)은 NAT Gateway → IGW.
- 보안그룹: RDS(5432)와 Redis(6379)는 소스가 "EKS 노드 SG"로 제한된다.

## 4. 컴퓨트: EKS

- **컨트롤플레인**은 AWS 관리 영역에 있다(우리 VPC 밖). kubectl은 EKS API 엔드포인트로 간다.
- **워커 노드**는 관리형 노드그룹: t3.medium, 기본 2대(AZ별 1대), 부하 시 ASG가 최대 4대까지 증설.
- Pod 스케일링은 HPA(CPU 60%, 2~6개, metrics-server 필요),
  노드 스케일링은 노드그룹 ASG — 이중 스케일링 구조.
- Spring Pod는 topologySpreadConstraints로 AZ 양쪽에 고르게 분산된다.

### ALB는 Terraform이 만들지 않는다 (중요)

ALB는 클러스터 안의 **AWS Load Balancer Controller**가 Ingress 리소스를 감지해 동적으로 생성한다.
컨트롤러의 IAM 권한(IRSA)은 Terraform(`eks.tf`의 lb_controller_role)이 만든다.

→ 따라서 ALB는 **Terraform state에 없다.** `terraform destroy`만 치면 ALB가 고아로 남아
VPC 삭제가 실패하고 과금이 계속된다. **철거는 반드시 `scripts/teardown.ps1`** (Ingress 먼저 삭제).

## 5. 애플리케이션 계층

Spring Boot 단일 애플리케이션, 내부적으로 Query/Command 책임 분리(CQRS-lite).

- **Query**: Redis 우선 조회(cache-aside) → 미스 시 PostgreSQL → Redis 재캐싱. MyBatis.
- **Command**: 등록·입찰 등 상태 변경. JPA. 처리 순서가 계약이다:

```
① Redis 분산 락 → ② 검증 → ③ PostgreSQL 커밋
→ ④ Redis 현재가 갱신 + Pub/Sub 브로드캐스트   (실시간 경로)
→ ⑤ Kafka 이벤트 발행                          (비동기 후처리 경로)
```

④가 ③보다 앞서면 DB 커밋 실패 시 존재하지 않는 입찰가가 화면에 뿌려진다 — 순서 고정.

### 두 개의 메시지 채널 (혼동 금지)

| 채널 | 특성 | 용도 |
|---|---|---|
| Redis Pub/Sub | 밀리초, 휘발(저장 안 함) | 현재가 실시간 브로드캐스트 — Pod들 간 WebSocket 전파 |
| Kafka (StatefulSet, 단일 브로커) | 저장·재소비 보장, 수초 허용 | 알림톡 발송, AI 분석 요청, 통계 |

Kafka가 단일 브로커인 것은 의도된 선택이다: 이벤트 원본이 PostgreSQL에 커밋되어 있어
브로커 유실 시 DB 기준 재발행이 가능하고, 시연 규모에서 브로커 다중화는 과설계다.

## 6. 데이터 계층

- **PostgreSQL (RDS)** — 최종 진실(Source of Truth). 사용자·상품·경매·입찰·결제.
  **pgvector 확장을 같은 인스턴스에 설치**해 상품 임베딩 벡터 검색(추천)도 담당한다.
  현재 규모에서는 동거가 맞고, 벡터 검색이 입찰 트랜잭션과 경합하기 시작하면
  Read Replica 또는 전용 인스턴스로 분리하는 확장 경로를 둔다.
  풀 HA 모드에서 Multi-AZ Standby(장애 조치 전용, 읽기 불가)가 추가된다.
- **Redis (ElastiCache)** — 세 가지 역할: 조회 캐시 / 현재가 캐시 / 분산 락(+Pub/Sub).
  애플리케이션은 항상 primary 엔드포인트만 바라본다(Replica에 쓰면 READONLY 에러).
  풀 HA 모드에서 Replica + 자동 페일오버가 켜진다.
- **S3** — 상품 이미지. 서버를 거치지 않는 presigned URL 직접 업로드.
  버킷은 퍼블릭 차단, 조회도 presigned GET.

## 7. AI 계층 (온프레미스)

GPU가 있는 온프렘 서버에서 FastAPI로 서빙: 불법 판매글 탐지, 이상 거래(Shill Bidding) 탐지,
CLIP 임베딩 기반 상품 추천. Spring → AI는 HTTPS/REST(NAT 경유 아웃바운드),
결과 회신은 동기 응답 또는 API Key 검증 콜백. **AI는 입찰 경로 밖(비동기)** —
AI 서버 장애가 경매 진행을 막지 않으며, 탐지는 사후 보상(입찰 무효화·제재)으로 처리한다.
AI 서버는 DB를 직접 만지지 않는다 — 데이터 소유권은 Spring에 있다.

## 8. 외부 연동

토스페이/포트원(결제), 카카오 우편번호(주소), 스마트택배(배송 추적), 알리고 카카오 알림톡(알림).
모두 Spring에서 NAT를 통해 아웃바운드 호출. 결제 웹훅은 ALB로 인바운드(서명 검증 + 멱등 처리).

## 9. 현재 구현 상태 (2026-09 기준)

- ✅ 검증 완료: Terraform 71개 리소스 생성, EKS 노드 AZ 분산, ALB 자동 생성,
  smoke Pod 외부 응답(인터넷→ALB→Pod 전체 경로), teardown 후 과금 리소스 0 확인.
- ⏳ 대기: 백엔드 이미지(ECR에 dib-backend 푸시되면 spring.yaml로 즉시 배포 가능),
  Kafka·HPA 실배포(매니페스트 완성, 백엔드와 함께 배포), 온프렘 AI 연결.

## 10. 이 문서와 세트인 문서

- 실행 명령: `docs/RUNBOOK.md`
- 백엔드가 지킬 규칙: `docs/BACKEND_CHECKLIST.md`
- 처음부터 따라 하기: `docs/ATOZ_WINDOWS_GUIDE.md`
- 다이어그램 매핑·배포 상세: `docs/DEPLOYMENT_GUIDE.md`
