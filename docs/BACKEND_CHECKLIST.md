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
| `PHONE_VERIFICATION_HMAC_SECRET` | **기본값 없음 — 빠지면 Pod가 안 뜬다** | (매 배포 시 생성) |
| `DIB_SERVICE_HMAC_SECRET` | 백엔드 → AI 요청 서명 | (AI와 같은 값) |
| `DIB_AI_HMAC_SECRET` | AI → 백엔드 콜백 서명 | (AI와 같은 값, 위와는 다름) |
| `TOSS_SECRET_KEY` | 낙찰 자동결제(빌링) | (토스 콘솔) |
| `DIB_S3_BUCKET` | 상품 이미지 버킷 | `dib-product-images-b101a` |
| `AWS_REGION` | S3 리전 | `ap-northeast-2` |
| `DIB_AI_ENABLED` | AI 연동 on/off | `deploy.ps1`이 `true`로 바꿈 |
| `DIB_AI_MODERATION_ENABLED` | 상품 등록 시 AI 검수(GMS) 경유. `false`면 즉시 승인 | `deploy.ps1`이 `true`로 바꿈 |
| `GEMINI_API_KEY` 등 | **AI 전용 Secret `dib-ai-secrets`** — 검수 모델(GMS) 키·주소·모델명 | `bootstrap.ps1`이 `$HOME\.dib-gms-key`에서 읽음 |
| `DIB_AI_BASE_URL` | AI 서버 주소 (같은 클러스터) | `http://dib-ai:8000` |
| `DIB_AI_CALLBACK_BASE_URL` | AI가 결과를 돌려보낼 주소 | `http://dib-backend` |
| `KAKAO_CLIENT_ID` | 카카오 REST API 키. 없으면 카카오 로그인만 `KAKAO_AUTH_FAILED` | (카카오 개발자 콘솔) |
| `KAKAO_CLIENT_SECRET` | 카카오 클라이언트 시크릿 (선택) | |
| `KAKAO_REDIRECT_URIS` | 허용 리다이렉트 URI. **앱의 `DIB_KAKAO_REDIRECT_URI`와 글자 그대로 일치** | `dib://oauth/kakao/callback` |
| `LIVEKIT_URL` | 라이브 송출 서버. 비면 방송 시작(토큰 발급)만 실패 | `wss://xxx.livekit.cloud` |
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | LiveKit 프로젝트 키 | (LiveKit 콘솔) |
| `DIB_DATABASE_URL` | **AI 전용** — AI가 DB를 직접 읽는다 | `postgresql://auction:…@…:5432/auction` |
| `DIB_EMBED_DATABASE_URL` | **AI 전용** — 임베딩 저장소 | 위와 동일 |

**기본값이 없는 값은 기동 시점에 터진다.** `application.yaml`에 `${VAR}`를 기본값 없이 쓰면
플레이스홀더 해석 실패로 컨텍스트가 아예 안 올라와 CrashLoopBackOff가 된다. 새로 추가할 때는
이 표와 `scripts/bootstrap.ps1`을 **같은 커밋에서** 같이 고칠 것. 없어도 되는 값이면 `${VAR:}`로 둔다.

> 예전 계약에 있던 `AI_SERVER_URL` / `AI_API_KEY` 는 **어떤 클래스에도 바인딩되지 않는 죽은 값**이었다.
> 실제 설정은 `dib.ai.*`(`AiServerProperties`)이고 백엔드↔AI 인증은 API 키가 아니라 HMAC이다.
> 두 값은 계약에서 제거했다.

고정 계약: 컨테이너 포트 **8080**, 헬스 경로 **`/actuator/health`** (없으면 Pod가 안 뜸), DB명/계정 **auction**.
Pod는 ServiceAccount **`dib-backend`** 로 뜬다 (상품 이미지 S3 접근 IRSA).

## 1. 무상태 (Stateless) — 최우선

- `HttpSession`, `@SessionAttributes`, static 변수에 사용자별 상태 저장 **금지**.
  Pod가 2~6개로 늘고 줄며, 같은 유저의 연속 요청이 서로 다른 Pod에 떨어진다.
- 상태의 자리: 인증=JWT, 공유 상태=Redis, 영속=PostgreSQL.
- 로컬 인메모리 캐시(Caffeine 등)는 카테고리 목록처럼 불변 데이터만.
  **현재가·입찰 상태는 절대 로컬 캐시 금지** — Redis가 유일한 진실.
- **업로드 파일을 컨테이너 디스크에 쓰지 말 것.** 올린 Pod에만 남아서 다른 Pod로 간 조회가 404가
  되고, Pod가 재시작하면 통째로 사라진다. 상품 이미지는 S3(`dib.storage.provider=s3`).
  로컬 디스크 구현(`provider=local`)은 IDE·docker compose 전용이다.

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
