# 경매 서비스 배포 설명서 (최종 아키텍처 기준)

> 최종 다이어그램과 1:1로 대응하는 배포 매뉴얼.
> 순서대로 따라 하면 그림의 모든 박스가 실제로 뜨고, 마지막 장의 절차대로 완전히 삭제된다.
>
> 전략은 동일: 개발은 로컬 Docker Compose, AWS 배포는 시연·부하테스트 때만 Terraform으로 생성 → 삭제.

---

## 0. 다이어그램 ↔ 코드 매핑표

배포 전에 이 표부터. 그림의 박스 하나가 어떤 코드/명령으로 만들어지는지의 지도다.

| 다이어그램 박스 | 만들어지는 방법 | 파일 |
|---|---|---|
| AWS Cloud (지역: 서울) | provider 설정 | `ephemeral/main.tf` |
| VPC (10.0.0.0/16) | VPC 모듈 | `ephemeral/vpc.tf` |
| Public subnet A/C + Internet Gateway | VPC 모듈 (public_subnets) | `ephemeral/vpc.tf` |
| NAT Gateway A/C (AZ별 1개) | VPC 모듈 (one_nat_gateway_per_az) | `ephemeral/vpc.tf` |
| Application Load Balancer | **Terraform이 아니라** K8s Ingress가 생성 | `k8s/ingress.yaml` |
| Kubernetes Cluster | EKS 모듈 | `ephemeral/eks.tf` |
| Private App subnet A/C + EC2 #1/#2 (Worker Node) | VPC 모듈(private_subnets) + EKS 노드그룹 | `ephemeral/vpc.tf`, `eks.tf` |
| Spring Boot Pod (Websocket/Query/Command) | Deployment | `k8s/spring-deployment.yaml` |
| Kafka Cluster (K8s StatefulSet) | StatefulSet | `k8s/kafka.yaml` |
| Private Data subnet A/C | VPC 모듈 (database_subnets) | `ephemeral/vpc.tf` |
| RDS PostgreSQL Primary → Standby (Multi-AZ) | RDS 리소스 (multi_az) | `ephemeral/rds.tf` |
| ElastiCache Redis Primary → Replica | Replication Group | `ephemeral/elasticache.tf` |
| S3 Storage (상품 이미지) | S3 리소스 (상시 유지) | `persistent/s3.tf` |
| 외부 API (HTTPS, NAT 경유) | 코드 아님 — NAT가 나가는 길 | 자동 |
| AI Server (On-Premise) | AWS 밖 — HTTPS/REST 연동 | 6장 참고 |

비용 주의: 이 그림은 **풀 HA 구성**(NAT 2개, RDS Multi-AZ, Redis Replica)이라 시간당 비용이
이전 절약 구성의 약 2배다. 그래서 Terraform에 `full_ha` 스위치를 넣어서
**발표·부하테스트 날은 그림 그대로(true), 개인 테스트 날은 절약 모드(false)**로 띄울 수 있게 한다.

| 모드 | NAT | RDS | Redis | 4시간 비용 |
|---|---|---|---|---|
| `full_ha = true` (그림 그대로) | A/C 2개 | Multi-AZ (Standby 포함) | Primary+Replica | 약 $4~5 |
| `full_ha = false` (절약) | 1개 | 단일 인스턴스 | 단일 노드 | 약 $2~3 |

---

## 1. 사전 준비 (1회만)

### 1-1. 도구 설치 확인 (팀원 전원)

```bash
brew install awscli terraform kubectl helm k6     # macOS 기준
aws configure                                     # region: ap-northeast-2
aws sts get-caller-identity                       # 계정 확인되면 OK
```

### 1-2. 계정 안전장치

AWS Budgets에서 월 $10 / $30 알림 2개 생성. 리전은 서울(ap-northeast-2) 고정.
이건 배포 순서 1번보다 먼저다 — 지우는 걸 까먹은 날 이 알림이 지갑을 지킨다.

### 1-3. Terraform state 버킷 (부트스트랩, 1회)

```bash
aws s3 mb s3://dib-tfstate-<팀명> --region ap-northeast-2
aws s3api put-bucket-versioning --bucket dib-tfstate-<팀명> \
  --versioning-configuration Status=Enabled
```

### 1-4. 저장소 구조

```
auction/
├── app/                       # Native Kotlin App (Android)
├── backend/                   # Spring Boot (+ Dockerfile)
├── ai-server/                 # FastAPI (온프렘 배포용, + Dockerfile)
├── infra/
│   ├── persistent/            # 상시: ECR, S3
│   ├── ephemeral/             # 임시: VPC, EKS, RDS, Redis
│   └── k8s/                   # kafka, spring, ingress, hpa
├── load-test/bid-scenario.js
├── docker-compose.yml
└── Makefile
```

---

## 2. Step 1 — 상시 스택 생성 (ECR + S3, 1회만)

```hcl
# infra/persistent/main.tf
terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-<팀명>"
    key    = "persistent/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
provider "aws" { region = "ap-northeast-2" }

# 다이어그램의 [S3 Storage — 상품 이미지]
resource "aws_s3_bucket" "product_images" {
  bucket        = "dib-product-images-<팀명>"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.product_images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  # 앱에는 presigned URL로 이미지 제공 (버킷 직접 공개 금지)
}

# 컨테이너 이미지 저장소
resource "aws_ecr_repository" "backend" {
  name         = "dib-backend"
  force_delete = true
}
```

```bash
cd infra/persistent && terraform init && terraform apply
# 이 스택은 프로젝트가 끝날 때까지 절대 destroy 하지 않는다
```

## 3. Step 2 — 이미지 빌드 & ECR 푸시 (코드 바뀔 때마다)

```bash
export ECR=<계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com

aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin $ECR

docker build -t $ECR/dib-backend:latest ./backend
docker push $ECR/dib-backend:latest
```

> GitHub Actions로 main 푸시마다 자동화해두면 시연 당일 이 단계가 사라진다.
> Apple Silicon 맥에서 빌드하면 **반드시 `docker build --platform linux/amd64`** —
> 안 하면 EKS(amd64) 노드에서 `exec format error`로 Pod가 안 뜬다. 최다 빈출 사고.

---

## 4. Step 3 — 임시 스택 Terraform (그림의 AWS 안쪽 전부)

### 4-1. 뼈대와 HA 스위치

```hcl
# infra/ephemeral/main.tf
terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-<팀명>"
    key    = "ephemeral/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
provider "aws" { region = "ap-northeast-2" }

variable "db_password" { sensitive = true }   # export TF_VAR_db_password=... 로 주입
variable "full_ha" {
  description = "true = 다이어그램 그대로(NAT 2, Multi-AZ, Redis Replica) / false = 절약 모드"
  type        = bool
  default     = true
}
```

### 4-2. VPC — 3계층 서브넷 (그림의 Public / Private App / Private Data)

```hcl
# infra/ephemeral/vpc.tf
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "dib-vpc"
  cidr = "10.0.0.0/16"                            # 그림의 VPC (10.0.0.0/16)
  azs  = ["ap-northeast-2a", "ap-northeast-2c"]   # 그림의 A / C

  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]    # Public subnet A/C — ALB, NAT
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24"]  # Private App subnet A/C — EKS 노드
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24"]  # Private Data subnet A/C — RDS, Redis

  enable_nat_gateway     = true
  single_nat_gateway     = !var.full_ha    # 절약 모드면 NAT 1개
  one_nat_gateway_per_az = var.full_ha     # 그림 그대로면 NAT Gateway A/C 2개

  # ALB 컨트롤러가 서브넷을 찾는 태그 — 빠뜨리면 ALB가 안 생긴다 (최다 빈출 함정)
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
```

인터넷 게이트웨이, 라우팅 테이블(퍼블릭→IGW, 프라이빗→NAT)은 모듈이 자동 생성한다.
그림의 "외부 API 호출은 NAT Gateway 경유" 경로가 이 라우팅으로 만들어지는 것.

### 4-3. EKS — 그림의 Kubernetes Cluster + EC2 #1/#2

```hcl
# infra/ephemeral/eks.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "dib-eks"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets          # 노드는 Private App subnet에만

  cluster_endpoint_public_access           = true  # 노트북에서 kubectl 치기 위함
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    app = {
      instance_types = ["t3.medium"]
      min_size       = 2        # 그림의 EC2 #1, #2 — AZ별 1대씩 분산 배치됨
      desired_size   = 2
      max_size       = 4        # 부하 시 ASG가 여기까지 증설
    }
  }

  cluster_addons = { coredns = {}, kube-proxy = {}, vpc-cni = {} }
}

output "cluster_name" { value = module.eks.cluster_name }
```

> Kafka는 그림대로 **K8s StatefulSet**으로 클러스터 안에 배포하므로(5장)
> 전용 EC2 노드그룹은 만들지 않는다. 별도 노드에 격리하고 싶어지면 그때
> taint 있는 노드그룹을 추가하면 된다.

### 4-4. RDS — 그림의 Primary → (Multi-AZ Failover) → Standby

```hcl
# infra/ephemeral/rds.tf
resource "aws_db_subnet_group" "main" {
  name       = "dib-db"
  subnet_ids = module.vpc.database_subnets       # Private Data subnet A/C
}

resource "aws_security_group" "rds" {
  name   = "dib-rds-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]  # EKS 노드에서만 접근 허용
  }
}

resource "aws_db_instance" "postgres" {
  identifier        = "dib-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20

  db_name  = "auction"
  username = "auction"
  password = var.db_password

  multi_az               = var.full_ha            # 그림의 Standby가 이 한 줄
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  apply_immediately   = true
}

output "rds_endpoint" { value = aws_db_instance.postgres.address }
```

> Standby는 별도 리소스가 아니다 — `multi_az = true` 한 줄이면 AWS가 다른 AZ에
> 동기 복제본을 만들고 장애 시 자동 승격한다. 그림에 박스가 2개여도 코드는 1개인 이유.
> pgvector는 첫 마이그레이션(Flyway V1)에 `CREATE EXTENSION IF NOT EXISTS vector;` 포함시킬 것.

### 4-5. ElastiCache — 그림의 Redis Primary → (Replication) → Replica

```hcl
# infra/ephemeral/elasticache.tf
resource "aws_elasticache_subnet_group" "main" {
  name       = "dib-redis"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_security_group" "redis" {
  name   = "dib-redis-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

# 그림처럼 Primary + Replica면 단일 cluster가 아니라 replication group을 쓴다
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "dib-redis"
  description          = "auction cache + lock + pubsub"

  engine     = "redis"
  node_type  = "cache.t4g.micro"

  num_cache_clusters         = var.full_ha ? 2 : 1   # 2 = Primary + Replica
  automatic_failover_enabled = var.full_ha            # Primary 죽으면 Replica 자동 승격
  multi_az_enabled           = var.full_ha            # Replica를 다른 AZ(C)에 배치

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}

output "redis_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
```

> 애플리케이션은 primary_endpoint 하나만 바라보면 된다. 페일오버가 나면
> 그 엔드포인트가 새 Primary를 가리키도록 AWS가 알아서 바꾼다.
> (분산 락·쓰기는 반드시 Primary 엔드포인트로 — Replica에 쓰면 에러다)

### 4-6. 생성 실행

```bash
cd infra/ephemeral
export TF_VAR_db_password=$(openssl rand -base64 24)
echo $TF_VAR_db_password > ~/.dib-db-pass    # 잃어버리면 Secret 못 만든다

terraform init
terraform apply          # 계획 확인 후 yes — 약 15~20분 (EKS가 대부분)
```

apply가 끝나면 그림에서 **ALB를 제외한 AWS 쪽 박스 전부**가 존재하는 상태다.
ALB는 다음 장의 Ingress가 만든다.

---

## 5. Step 4~5 — 클러스터 부트스트랩 & 앱 배포

배포 순서는 고정이다. 의존성 때문에 순서를 바꾸면 어딘가는 실패한다.

```
kubeconfig → ALB Controller + metrics-server → Secret → Kafka → Spring → Ingress → HPA
```

### 5-1. kubectl 연결

```bash
aws eks update-kubeconfig --name dib-eks --region ap-northeast-2
kubectl get nodes -o wide
# 노드 2대가 서로 다른 AZ(2a, 2c)에 떠 있으면 그림의 EC2 #1/#2 완성
```

### 5-2. AWS Load Balancer Controller + metrics-server

```bash
# IRSA용 IAM 정책 (공식 iam_policy.json 다운로드 후 1회)
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=dib-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<IRSA_ROLE_ARN>

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### 5-3. 접속 정보 Secret (Terraform output → K8s)

```bash
cd infra/ephemeral
kubectl create secret generic dib-secrets \
  --from-literal=DB_URL="jdbc:postgresql://$(terraform output -raw rds_endpoint):5432/auction" \
  --from-literal=DB_PASSWORD="$TF_VAR_db_password" \
  --from-literal=REDIS_HOST="$(terraform output -raw redis_endpoint)" \
  --from-literal=KAFKA_SERVERS="kafka-0.kafka:9092" \
  --from-literal=JWT_SECRET="$(openssl rand -base64 48)" \
  --from-literal=AI_SERVER_URL="https://<온프렘-AI-서버-주소>" \
  --from-literal=AI_API_KEY="<온프렘과 맞춘 키>"
```

### 5-4. Kafka StatefulSet — 그림의 [Kafka Cluster (K8s StatefulSet)]

```yaml
# infra/k8s/kafka.yaml
apiVersion: v1
kind: Service
metadata: { name: kafka }
spec:
  clusterIP: None                      # headless — kafka-0.kafka 로 DNS 고정
  selector: { app: kafka }
  ports: [{ port: 9092 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: kafka }
spec:
  serviceName: kafka
  replicas: 1                          # 시연 규모 단일 브로커 (유실 시 DB 기준 재발행)
  selector: { matchLabels: { app: kafka } }
  template:
    metadata: { labels: { app: kafka } }
    spec:
      containers:
        - name: kafka
          image: apache/kafka:3.8.0
          ports: [{ containerPort: 9092 }]
          resources:
            requests: { cpu: "250m", memory: "1Gi" }
          env:
            - { name: KAFKA_NODE_ID, value: "1" }
            - { name: KAFKA_PROCESS_ROLES, value: "broker,controller" }
            - { name: KAFKA_CONTROLLER_QUORUM_VOTERS, value: "1@kafka-0.kafka:9093" }
            - { name: KAFKA_LISTENERS, value: "PLAINTEXT://:9092,CONTROLLER://:9093" }
            - { name: KAFKA_ADVERTISED_LISTENERS, value: "PLAINTEXT://kafka-0.kafka:9092" }  # localhost 아님!
            - { name: KAFKA_CONTROLLER_LISTENER_NAMES, value: "CONTROLLER" }
            - { name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, value: "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" }
            - { name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR, value: "1" }
            - { name: KAFKA_AUTO_CREATE_TOPICS_ENABLE, value: "true" }
```

### 5-5. Spring Boot — 그림의 [Spring Boot Pod] (양쪽 서브넷에 분산)

```yaml
# infra/k8s/spring-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: dib-backend }
spec:
  replicas: 2
  selector: { matchLabels: { app: dib-backend } }
  template:
    metadata: { labels: { app: dib-backend } }
    spec:
      terminationGracePeriodSeconds: 40
      topologySpreadConstraints:            # Pod를 AZ별로 고르게 — 그림처럼 A/C 양쪽 배치
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: dib-backend } }
      containers:
        - name: app
          image: <계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com/dib-backend:latest
          ports: [{ containerPort: 8080 }]
          envFrom: [{ secretRef: { name: dib-secrets } }]
          resources:
            requests: { cpu: "500m", memory: "768Mi" }   # 없으면 HPA 작동 안 함
            limits:   { memory: "1280Mi" }
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            initialDelaySeconds: 20
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            initialDelaySeconds: 40
          lifecycle:
            preStop: { exec: { command: ["sh","-c","sleep 10"] } }  # WS 정리 시간
---
apiVersion: v1
kind: Service
metadata: { name: dib-backend }
spec:
  selector: { app: dib-backend }
  ports: [{ port: 80, targetPort: 8080 }]
```

### 5-6. Ingress — 그림의 [Application Load Balancer]가 이걸로 생성됨

```yaml
# infra/k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dib-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing        # Public subnet에 생성됨
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
    # ↑ WebSocket 필수. 기본 60초면 경매 구경 중인 유저가 1분마다 끊긴다
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: dib-backend, port: { number: 80 } } }
```

### 5-7. HPA

```yaml
# infra/k8s/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: dib-backend }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: dib-backend }
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 60 } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 120 }   # WS 연결 보호
```

### 5-8. 배포 실행

```bash
kubectl apply -f infra/k8s/kafka.yaml
kubectl rollout status statefulset/kafka --timeout=180s

kubectl apply -f infra/k8s/spring-deployment.yaml
kubectl rollout status deployment/dib-backend --timeout=300s

kubectl apply -f infra/k8s/ingress.yaml
kubectl apply -f infra/k8s/hpa.yaml

kubectl get ingress dib-ingress
# ADDRESS 칸에 ALB 주소가 뜨는 데 2~3분 — 이 주소가 앱의 API_BASE_URL
```

---

## 6. Step 6 — 온프렘 AI 서버 연결 (그림의 점선 화살표)

그림의 점선 두 개가 이 연동이다: Spring → AI 서버 "분석 요청/추천 요청(HTTPS/REST)",
AI 서버 → "분석 결과/추천 결과(HTTPS/REST)".

**나가는 방향 (Spring → AI 서버)** 은 설정할 게 거의 없다. Pod의 아웃바운드 트래픽이
NAT Gateway를 통해 나가므로, AI 서버 주소만 Secret(`AI_SERVER_URL`)에 넣으면 끝.
단, 온프렘 쪽에서 방화벽을 연다면 **NAT Gateway의 EIP 2개**만 화이트리스트에 넣으면 된다.
(`terraform output`에 nat EIP를 추가해두면 편함)

**들어오는 방향 (AI 서버 → 결과 회신)** 은 두 방식 중 하나:

| 방식 | 구현 | 권장 상황 |
|---|---|---|
| ① 동기 응답 | Spring이 REST 호출하고 응답으로 결과 수신 (별도 인바운드 불필요) | 추천처럼 즉시 결과가 나오는 경우 — **기본 선택** |
| ② 콜백 | AI 서버가 ALB의 `/api/internal/ai-callback`으로 POST (API Key 헤더 필수) | 탐지처럼 분석이 오래 걸리는 경우 |

②를 쓸 경우 보안 최소 3종 세트: HTTPS만 허용, `X-API-KEY` 헤더 검증(Secret의 AI_API_KEY),
콜백 엔드포인트는 인증 필터에서 별도 처리(사용자 JWT와 분리).

> 시연 당일 리스크 메모: 학교/행사장 네트워크에서 온프렘 서버가 안 붙는 사고가 흔하다.
> ai-server 이미지를 ECR에 올려두고, 비상시 EKS에 `kubectl apply` 한 번으로 띄우는
> 플랜 B 매니페스트를 준비해둘 것 (Secret의 AI_SERVER_URL만 내부 주소로 교체).

---

## 7. Step 7 — 앱 연결 & 스모크 테스트

```bash
export ALB=$(kubectl get ingress dib-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
```

1. Kotlin 앱의 `BASE_URL`을 위 ALB 주소로 교체하고 빌드 (BuildConfig 필드로 빼두면 한 줄 수정)
2. 스모크 시나리오 — 이 순서 그대로 그림의 ①~⑩ 검증이 된다:

| 확인 | 검증되는 것 |
|---|---|
| 회원가입 → 로그인 | ① JWT 발급 |
| 상품 등록 (이미지 포함) | S3 presigned 업로드, ⑦ Kafka 등록 이벤트 |
| 상품 목록 두 번 조회 | ④ 두 번째가 빨라야 함 (Redis 캐시 히트) |
| 폰 2대로 같은 상품에 동시 입찰 | ⑤ 분산 락 — 한쪽은 성공, 한쪽은 갱신가 안내 |
| 입찰 순간 다른 폰 화면 | ⑥ WebSocket 실시간 현재가 갱신 |
| 낙찰 처리 | ⑧ 알림톡 수신, AI 서버 로그에 분석 요청 확인 |

3. 부하 테스트: `BASE_URL=http://$ALB k6 run load-test/bid-scenario.js`
   돌리는 동안 `kubectl get hpa -w`로 Pod 증가 장면을 녹화해둘 것 (포트폴리오 자료)

---

## 8. Step 8 — 철거 (순서 엄수)

**★ 규칙: Ingress를 지우기 전에 terraform destroy를 치지 않는다.**
ALB는 K8s가 만들었기 때문에 Terraform이 모른다. 순서를 어기면 ALB와 보안그룹이
고아로 남아 VPC 삭제가 실패하고, 그 잔해가 계속 과금된다.

```bash
# 1. K8s가 만든 AWS 리소스부터 (ALB 삭제 유발)
kubectl delete ingress --all
kubectl delete -f infra/k8s/ --ignore-not-found
sleep 90    # ALB 컨트롤러가 실제 ALB를 지울 시간

# 2. Terraform 스택 삭제 (~15분)
cd infra/ephemeral && terraform destroy -auto-approve

# 3. 삭제 검증 — 전부 비어 있어야 함
aws eks list-clusters --region ap-northeast-2
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
```

persistent 스택(ECR, S3)은 남긴다. 다음 배포는 Step 3부터 다시 시작하면 되고,
이미지가 ECR에 있으므로 약 25분이면 전체가 다시 뜬다.
다음 날 Cost Explorer에서 비용이 예상 범위인지 확인하는 것까지가 철거다.

---

## 9. Makefile (전체 요약)

```makefile
REGION  = ap-northeast-2
CLUSTER = dib-eks

up:                  ## 인프라 생성 (~20분)
	cd infra/ephemeral && terraform init && terraform apply -auto-approve

bootstrap:           ## 컨트롤러/시크릿 (~5분)
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)
	./scripts/install-alb-controller.sh
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	./scripts/create-secrets.sh

deploy:              ## 앱 배포 (~5분)
	kubectl apply -f infra/k8s/kafka.yaml && kubectl rollout status statefulset/kafka --timeout=180s
	kubectl apply -f infra/k8s/spring-deployment.yaml && kubectl rollout status deployment/dib-backend --timeout=300s
	kubectl apply -f infra/k8s/ingress.yaml -f infra/k8s/hpa.yaml
	kubectl get ingress

down:                ## ★ 철거 — Ingress 먼저
	kubectl delete ingress --all --ignore-not-found
	kubectl delete -f infra/k8s/ --ignore-not-found
	sleep 90
	cd infra/ephemeral && terraform destroy -auto-approve

verify-empty:        ## 삭제 검증
	./scripts/verify-teardown.sh
```

시연 당일 타임라인: `make up`(T+0) → `make bootstrap deploy`(T+20분) → 스모크(T+30분)
→ 시연/부하테스트 → `make down`(종료 시각 −20분) → `make verify-empty`.

---

## 10. 트러블슈팅 (증상 → 원인)

| 증상 | 원인 / 조치 |
|---|---|
| Pod `ImagePullBackOff` | ECR 태그 오타, 또는 Apple Silicon에서 `--platform linux/amd64` 없이 빌드 |
| Pod `exec format error` | 100% 아키텍처 불일치 — amd64로 재빌드 |
| Ingress ADDRESS가 계속 빈칸 | 서브넷 `kubernetes.io/role/elb` 태그 또는 ALB 컨트롤러 IRSA 문제. `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA `<unknown>/60%` | metrics-server 미설치 or Deployment에 resources.requests 없음 |
| Spring이 RDS 연결 실패 | RDS SG의 소스가 EKS 노드 SG인지, DB_URL의 엔드포인트가 최신 output인지 |
| Redis 쓰기에서 READONLY 에러 | Replica 엔드포인트에 쓰고 있음 — primary_endpoint 사용 |
| Kafka 연결은 되는데 메시지 안 옴 | ADVERTISED_LISTENERS가 `kafka-0.kafka:9092`인지 (localhost면 안 됨) |
| WebSocket 1분마다 끊김 | ALB idle_timeout=3600 annotation 누락 |
| pgvector 함수 없음 | Flyway V1에 `CREATE EXTENSION IF NOT EXISTS vector;` 추가 |
| destroy가 VPC에서 멈춤 | Ingress 안 지우고 destroy함 — 남은 ALB/SG 수동 삭제 후 재시도 (8장) |
| 온프렘 AI 호출 timeout | 온프렘 방화벽에 NAT EIP 미등록, 또는 행사장 네트워크 차단 — 플랜 B(6장)로 전환 |

---

## 11. 이 구성의 발표 한 줄

> "전 인프라를 Terraform으로 코드화해 3계층 서브넷(외부 노출은 ALB뿐, 앱과 데이터는
> 프라이빗 격리)과 AZ 이중화(노드·NAT·RDS Standby·Redis Replica)를 명령 두 줄로
> 재현 가능하게 만들었고, 시연 시에만 생성·삭제하는 운영으로 유지 비용을 월 $1 이하로 억제했습니다."
