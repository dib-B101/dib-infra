# 백엔드 개발 체크리스트 (인프라 계약)

> Spring Boot 코드가 이 인프라(EKS + ALB + Redis + RDS + Kafka) 위에서 돌기 위해
> 지켜야 하는 규칙. 로컬 도커에서 되던 게 배포 환경에서 안 되는 사고의 90%는 여기서 나온다.

## 0. 인프라가 주입하는 환경변수 (계약)

배포 환경에서는 K8s Secret(`dib-secrets`)이 아래 환경변수를 컨테이너에 주입한다.
`application-prod.yml`은 반드시 이 이름들을 참조해야 한다.

| 환경변수 | 내용 | 예시 |
|---|---|---|
| `DB_URL` | JDBC URL | `jdbc:postgresql://dib-db.xxx.rds.amazonaws.com:5432/auction` |
| `DB_PASSWORD` | DB 비밀번호 | (매 배포 시 생성) |
| `REDIS_HOST` | Redis primary 엔드포인트 | `dib-redis.xxx.cache.amazonaws.com` |
| `KAFKA_SERVERS` | Kafka 부트스트랩 | `kafka-0.kafka:9092` |
| `JWT_SECRET` | JWT 서명 키 | (매 배포 시 생성) |
| `AI_SERVER_URL` | 온프렘 AI 서버 주소 | `https://...` |
| `AI_API_KEY` | AI 서버 인증 키 | (온프렘과 합의) |

고정 계약: 컨테이너 포트 **8080**, 헬스 경로 **`/actuator/health`** (없으면 Pod가 안 뜸), DB명/계정 **auction**.

## 1. 무상태 (Stateless) — 최우선

- `HttpSession`, `@SessionAttributes`, static 변수에 사용자별 상태 저장 **금지**.
  Pod가 2~6개로 늘고 줄며, 같은 유저의 연속 요청이 서로 다른 Pod에 떨어진다.
- 상태의 자리: 인증=JWT, 공유 상태=Redis, 영속=PostgreSQL.
- 로컬 인메모리 캐시(Caffeine 등)는 카테고리 목록처럼 불변 데이터만.
  **현재가·입찰 상태는 절대 로컬 캐시 금지** — Redis가 유일한 진실.

## 2. 설정 외부화

- DB/Redis/Kafka 주소, 시크릿을 코드나 yml에 하드코딩 금지 — 전부 `${ENV_VAR}` 참조.
- `application-local.yml`(localhost) / `application-prod.yml`(환경변수) 프로필 분리 유지.
- Dockerfile은 `--spring.profiles.active=prod`로 실행된다 (infra 레포의 매니페스트 기준).

## 3. Actuator 필수

```groovy
implementation 'org.springframework.boot:spring-boot-starter-actuator'
```
- K8s가 `/actuator/health`로 생존 판정한다. 의존성이 없으면 **CrashLoopBackOff**.
- 권장: `management.endpoint.health.probes.enabled=true` (readiness/liveness 분리).

## 4. WebSocket 브로드캐스트는 Redis Pub/Sub 경유

- 세션 목록을 돌며 직접 send 금지 — **자기 Pod에 붙은 유저에게만 가는 버그**가 된다.
- 흐름: 입찰 처리 Pod → Redis Pub/Sub 발행 → 모든 Pod가 구독 → 각자 자기 WebSocket 세션에 push.
- 클라이언트 재연결 시: bid-snapshot API(REST)로 현재 상태 동기화 후 재구독,
  수신 메시지의 version이 스냅샷 이하이면 폐기.

## 5. 입찰 처리 순서 계약

```
① Redis 분산 락 획득 (Redisson 권장, TTL 필수)
② 입찰가·자격 검증
③ PostgreSQL 트랜잭션 커밋          ← 진실의 확정 지점
④ Redis 현재가 캐시 갱신 + Pub/Sub   ← 반드시 커밋 후 (유령 입찰가 방지)
⑤ Kafka 이벤트 발행                  ← 알림·AI·통계 등 비동기 후처리 전용
```
- ⑤는 트랜잭션 안에서 발행 금지 — 롤백돼도 이벤트가 나가버린다.
  `@TransactionalEventListener(phase = AFTER_COMMIT)` 패턴 사용.
- Kafka 컨슈머는 멱등하게 (eventId 기준 중복 처리 방지).

## 6. Graceful Shutdown

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 25s
```
- HPA scale-in 시 SIGTERM → 처리 중 요청과 WebSocket 정리 시간 확보.
  (매니페스트의 preStop sleep 10초와 세트)

## 7. 로그·파일

- 로그는 **stdout**으로만 (파일 appender 금지) — `kubectl logs`로 수집.
- 로컬 디스크에 파일 저장 금지 — Pod는 언제든 사라진다. 파일은 S3 presigned URL로.

## 8. 커넥션 풀

```yaml
spring.datasource.hikari.maximum-pool-size: 10
```
- Pod 최대 6개 × 10 = 60 커넥션. RDS(t4g.micro) 한도를 넘지 않게 —
  풀 크기를 키우면 부하 테스트에서 커넥션 고갈로 죽는다.

## 9. 이미지 빌드 & ECR 푸시

```powershell
$ECR = "712710405297.dkr.ecr.ap-northeast-2.amazonaws.com"
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $ECR
docker build -t "$ECR/dib-backend:latest" .
docker push "$ECR/dib-backend:latest"
```
- 이미지가 ECR에 있어야 배포 가능. Apple Silicon 맥은 `--platform linux/amd64` 필수.
- 시간은 UTC로 저장, 표시만 KST (API 명세서 공통 규칙).
