# 경매 서비스 인프라 A to Z (윈도우 기준)

> 시작 상태: **AWS 계정 하나 만든 게 전부.**
> 끝 상태: 최종 다이어그램(VPC 3계층 서브넷, EKS, RDS Multi-AZ, Redis Replica, Kafka, ALB)이
> 실제로 떠서 앱이 붙고, 다 쓰면 완전히 삭제까지.
>
> 모든 명령은 **Windows PowerShell** 기준. 복사해서 그대로 붙여넣으면 되도록 작성했다.

## 전체 지도 (오늘 어디까지 왔는지 체크용)

| 장 | 내용 | 소요 시간 | 언제 하나 |
|---|---|---|---|
| 1장 | AWS 계정 마무리 세팅 (콘솔 클릭) | 30분 | 지금 1회 |
| 2장 | 윈도우에 개발 도구 설치 | 40분 | 팀원 전원 1회 |
| 3장 | AWS CLI 연결 | 10분 | 팀원 전원 1회 |
| 4장 | 프로젝트 폴더 구조 만들기 | 20분 | 1회 |
| 5장 | 로컬 개발 환경 (Docker Compose) | 30분 | 1회, 이후 매일 사용 |
| 6장 | Terraform 준비 + 상시 스택(ECR/S3) | 30분 | 1회 |
| 7장 | 이미지 빌드 & ECR 푸시 | 20분 | 코드 바뀔 때마다 |
| 8장 | 임시 스택 Terraform 코드 전체 | 40분 (작성) | 1회 작성, 이후 재사용 |
| 9장 | 클러스터 띄우기 + 부트스트랩 | 30분 (대기 포함) | 시연 날마다 |
| 10장 | 앱 배포 + ALB 주소 받기 | 15분 | 시연 날마다 |
| 11장 | 검증 (스모크 테스트) | 15분 | 시연 날마다 |
| 12장 | 철거 (삭제 + 검증) | 25분 | 시연 끝날 때마다 |

1~8장은 한 번만 하면 되는 준비이고, **시연 날 반복하는 건 9~12장뿐**이다.

---

## 0장. 5분 용어 사전 (이것만 알면 아래 전부 읽힌다)

- **Terraform**: "AWS에 뭘 만들지"를 텍스트 파일(.tf)로 적어두면, `terraform apply` 한 방에
  그대로 만들어주고 `terraform destroy` 한 방에 그대로 지워주는 도구. 우리 전략의 심장.
- **state 파일**: Terraform이 "내가 지금까지 뭘 만들었는지" 기록하는 장부. 우리는 S3에 보관한다.
  장부가 있어야 destroy가 정확히 그것만 지운다.
- **ECR**: AWS의 도커 이미지 저장소. Docker Hub의 AWS 버전.
- **kubectl**: 쿠버네티스 클러스터에 명령을 내리는 CLI. "Pod 띄워라, 상태 보여라" 전부 이걸로.
- **Helm**: 쿠버네티스용 패키지 설치 도구(apt/winget 같은 것). ALB 컨트롤러 설치에 씀.
- **매니페스트(yaml)**: "클러스터 안에 뭘 띄울지" 적는 파일. Terraform이 AWS 담당이면, yaml은 클러스터 안 담당.

---

## 1장. AWS 계정 마무리 세팅 (전부 콘솔 클릭, 30분)

지금 계정은 "루트 계정"만 있는 상태다. 루트는 금고 열쇠라서 평소에 쓰면 안 되고,
작업용 계정(IAM 사용자)을 따로 만들어 쓴다. 아래 순서 그대로.

### 1-1. 루트 계정에 MFA 걸기 (5분)

1. https://console.aws.amazon.com 접속 → 루트 이메일로 로그인
2. 우측 상단 계정 이름 클릭 → **보안 자격 증명(Security credentials)**
3. **MFA 할당(Assign MFA device)** → Authenticator app 선택
4. 폰에 Google Authenticator 설치 → QR 스캔 → 연속된 코드 2개 입력 → 완료

> 이거 안 하면 계정 털렸을 때 남의 채굴 서버 요금이 청구된다. 실화 단골 사고.

### 1-2. 작업용 IAM 사용자 만들기 (10분)

1. 콘솔 상단 검색창에 `IAM` 입력 → IAM 서비스 이동
2. 왼쪽 메뉴 **사용자(Users)** → **사용자 생성(Create user)**
3. 사용자 이름: `admin-yj` (본인 이름으로) → **AWS Management Console에 대한 사용자 액세스 권한 제공** 체크
   → "IAM 사용자를 생성하고 싶음" 선택 → 콘솔 비밀번호 직접 설정 → 다음
4. 권한 설정: **직접 정책 연결(Attach policies directly)** → `AdministratorAccess` 체크 → 다음 → 사용자 생성
   (실무라면 최소 권한이 원칙이지만, 팀 프로젝트에선 Admin으로 시작하는 게 현실적)
5. 생성된 사용자 클릭 → **보안 자격 증명 탭** → **액세스 키 만들기(Create access key)**
   → 사용 사례: **Command Line Interface (CLI)** 선택 → 확인 체크 → 생성
6. ★ **Access key ID**와 **Secret access key**가 딱 한 번 표시된다. `.csv 다운로드` 눌러서 보관.
   (Secret은 이 화면 닫으면 다시 못 본다. 잃어버리면 키를 새로 만들면 됨)

이제부터 콘솔 로그인도 루트가 아니라 이 IAM 사용자로 한다.
로그인 주소는 IAM 대시보드에 표시되는 `https://<계정ID>.signin.aws.amazon.com/console`.

### 1-3. 지갑 보호 — Budgets 알림 (10분, 건너뛰지 말 것)

1. 콘솔 검색창 `Budgets` → Billing and Cost Management의 Budgets 이동
2. **예산 생성(Create budget)** → 템플릿 사용 → **월별 비용 예산(Monthly cost budget)**
3. 예산 금액: `10` (USD) → 이메일 수신자: 팀 전원 이메일 → 생성
4. 같은 방식으로 `30` USD 예산 하나 더 생성

> 의미: 이번 달 누적 요금이 $10/$30 넘으면 메일이 온다. "지우는 걸 까먹은 날"을
> 하루 안에 잡아내는 마지노선. 우리 전략대로면 이 메일은 평생 안 와야 정상이다.

### 1-4. 리전 고정 (1분)

콘솔 우측 상단 리전 선택 → **아시아 태평양 (서울) ap-northeast-2** 선택.
앞으로 콘솔 볼 일이 있으면 항상 여기가 서울인지 먼저 확인한다.
(다른 리전에 실수로 만든 리소스는 화면에 안 보여서 못 지운다 — 유령 과금의 주범)

**1장 완료 체크**: 루트 MFA ✓ / IAM 사용자 + 액세스 키 CSV ✓ / Budgets 2개 ✓ / 리전 서울 ✓

---

## 2장. 윈도우에 개발 도구 설치 (40분, 팀원 전원)

### 2-1. WSL2 켜기 (Docker의 전제 조건)

PowerShell을 **관리자 권한으로** 열고 (시작 → "PowerShell" 검색 → 우클릭 → 관리자 권한으로 실행):

```powershell
wsl --install
```

끝나면 **재부팅**. 재부팅 후 Ubuntu 초기 설정 창이 뜨면 사용자명/비밀번호 아무거나 지정.

> 에러 "가상화를 사용할 수 없습니다"가 나오면: 재부팅 → BIOS 진입(보통 F2/DEL) →
> Intel VT-x 또는 AMD SVM **Enabled** → 저장 후 재부팅. 노트북은 대부분 기본 켜져 있음.

### 2-2. 도구 일괄 설치 (winget)

일반 PowerShell 창에서 한 줄씩:

```powershell
winget install -e --id Docker.DockerDesktop
winget install -e --id Amazon.AWSCLI
winget install -e --id Hashicorp.Terraform
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
winget install -e --id k6.k6
winget install -e --id Git.Git
```

전부 끝나면 **PowerShell 창을 닫았다 다시 연다** (PATH 반영).
Docker Desktop은 시작 메뉴에서 한 번 실행해서 "Engine running" 상태로 만들어 둔다
(Settings → General → "Use the WSL 2 based engine" 체크 확인).

### 2-3. 설치 확인 (전부 버전이 찍혀야 함)

```powershell
docker compose version
aws --version
terraform -version
kubectl version --client
helm version
k6 version
git --version
```

하나라도 "인식할 수 없는 명령"이면: 창 재시작 → 그래도 안 되면 `winget list <이름>`으로
설치 여부 확인 후 재설치.

---

## 3장. AWS CLI 연결 (10분)

1장에서 다운받은 CSV를 열어두고:

```powershell
aws configure
# AWS Access Key ID:     CSV의 Access key ID 붙여넣기
# AWS Secret Access Key: CSV의 Secret access key 붙여넣기
# Default region name:   ap-northeast-2
# Default output format: json
```

확인:

```powershell
aws sts get-caller-identity
```

`"Account": "123456789012"` 처럼 12자리 계정 번호가 나오면 성공.
**이 12자리 번호를 메모해 둘 것** — 앞으로 `<계정ID>` 자리에 계속 들어간다.

> 팀원들도 각자 이걸 해야 하나? 인프라를 만지는 사람(2~3명)만 하면 된다.
> 각자 1-2장의 방법으로 자기 IAM 사용자를 만들어 쓰는 게 정석이다 (키 공유 금지).

---

## 4장. 프로젝트 폴더 구조 만들기 (20분)

팀 GitHub 레포가 이미 있다면 그 안에 아래 구조만 추가하면 된다. 없으면:

```powershell
cd $HOME
mkdir auction; cd auction
git init

# 폴더 뼈대 생성
mkdir backend, ai-server, app
mkdir infra\persistent, infra\ephemeral, infra\k8s, scripts, load-test
```

최종 구조 (이 문서의 모든 파일 경로가 여기 기준):

```
auction\
├─ app\                     # Kotlin 앱 (Android Studio 프로젝트)
├─ backend\                 # Spring Boot + Dockerfile
├─ ai-server\               # FastAPI + Dockerfile
├─ infra\
│  ├─ persistent\           # 상시 스택: ECR, S3
│  ├─ ephemeral\            # 임시 스택: VPC, EKS, RDS, Redis
│  └─ k8s\                  # kafka.yaml, spring.yaml, ingress.yaml, hpa.yaml
├─ scripts\                 # PowerShell 자동화 스크립트 (.ps1)
├─ load-test\               # k6 시나리오
└─ docker-compose.yml
```

`.gitignore`에 최소 이것들 추가 (VS Code로 `auction\.gitignore` 만들기):

```
.terraform/
*.tfstate*
*.tfvars
.env
```

> ★ PowerShell 스크립트 실행이 처음이면 1회 설정 필요:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
> ```
> 안 하면 .ps1 실행 시 "이 시스템에서 스크립트를 실행할 수 없으므로" 에러가 난다.

---

## 5장. 로컬 개발 환경 — Docker Compose (30분)

평소 개발은 전부 여기서. AWS 안 켜도 된다. `auction\docker-compose.yml` 생성:

```yaml
services:
  postgres:
    image: pgvector/pgvector:pg16          # 벡터 검색 확장 포함 PostgreSQL
    environment:
      POSTGRES_DB: auction
      POSTGRES_USER: auction
      POSTGRES_PASSWORD: localdev
    ports: ["5432:5432"]
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./backend/db/init.sql:/docker-entrypoint-initdb.d/init.sql

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

  kafka:
    image: apache/kafka:3.8.0              # KRaft 단일 브로커
    ports: ["9092:9092"]
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"

volumes:
  pgdata:
```

`backend\db\init.sql` (첫 실행 때 자동 적용):

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

실행과 확인:

```powershell
cd $HOME\dib-infra
docker compose up -d
docker compose ps        # 3개 전부 Up 이면 성공
```

Spring Boot는 IntelliJ에서 프로필 `local`로 직접 실행 (localhost:5432/6379/9092 바라봄).
**여기서 회원가입 → 상품 등록 → 입찰 → WebSocket 현재가 갱신까지 되는 걸 확인한 뒤에**
AWS로 넘어간다. 로컬에서 안 되는 건 EKS에서도 안 된다.

Spring 설정은 프로필 2개로 분리해 둔다 (핵심 준비물):

```yaml
# application-local.yml — 로컬 개발용
spring:
  datasource: { url: "jdbc:postgresql://localhost:5432/auction", username: auction, password: localdev }
  data: { redis: { host: localhost, port: 6379 } }
  kafka: { bootstrap-servers: "localhost:9092" }

# application-prod.yml — EKS용 (값은 전부 K8s Secret이 환경변수로 주입)
spring:
  datasource: { url: "${DB_URL}", username: auction, password: "${DB_PASSWORD}" }
  data: { redis: { host: "${REDIS_HOST}", port: 6379 } }
  kafka: { bootstrap-servers: "${KAFKA_SERVERS}" }
```

`backend\Dockerfile`:

```dockerfile
FROM gradle:8-jdk21 AS build
WORKDIR /app
COPY build.gradle settings.gradle ./
COPY src ./src
RUN gradle bootJar --no-daemon

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar","--spring.profiles.active=prod"]
```

---

## 6장. Terraform 준비 + 상시 스택 (30분, 1회)

### 6-1. state 보관용 S3 버킷 (수동 1회 — 닭과 달걀 문제라 이것만 CLI로)

```powershell
# <팀명>을 소문자 영문으로 교체 (예: dib-tfstate-ssafy13a)
aws s3 mb s3://dib-tfstate-<팀명> --region ap-northeast-2
aws s3api put-bucket-versioning --bucket dib-tfstate-<팀명> --versioning-configuration Status=Enabled
```

### 6-2. 상시 스택 코드 — `infra\persistent\main.tf` (파일 하나에 전부)

```hcl
terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-<팀명>"          # 6-1의 버킷명
    key    = "persistent/terraform.tfstate"
    region = "ap-northeast-2"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "ap-northeast-2" }

# ── 다이어그램의 [S3 Storage: 상품 이미지] ─────────────────────
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
  # 앱은 presigned URL로 업로드/조회 (버킷 직접 공개 금지)
}

# ── 도커 이미지 저장소 ──────────────────────────────────────
resource "aws_ecr_repository" "backend" {
  name         = "dib-backend"
  force_delete = true
}

output "s3_bucket"    { value = aws_s3_bucket.product_images.bucket }
output "ecr_backend"  { value = aws_ecr_repository.backend.repository_url }
```

### 6-3. 실행

```powershell
cd $HOME\dib-infra\infra\persistent
terraform init      # 처음 1회 — 플러그인 다운로드
terraform plan      # 뭘 만들지 미리보기 (3 to add 나오면 정상)
terraform apply     # yes 입력
```

콘솔에서 확인하고 싶으면: 검색창 `ECR` → dib-backend 저장소가 보이면 성공.
**이 스택은 프로젝트 끝날 때까지 절대 destroy 하지 않는다.**

---

## 7장. 이미지 빌드 & ECR 푸시 (코드 바뀔 때마다, 20분)

```powershell
# 계정ID를 변수로 (3장에서 메모한 12자리)
$ACCOUNT = "123456789012"                     # ← 본인 것으로 교체
$ECR = "$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com"

# ECR 로그인 (12시간 유효, 만료되면 다시 실행)
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $ECR

# 빌드 & 푸시
cd $HOME\dib-infra
docker build -t "$ECR/dib-backend:latest" .\backend
docker push "$ECR/dib-backend:latest"
```

확인:

```powershell
aws ecr describe-images --repository-name dib-backend --query "imageDetails[].imageTags"
# ["latest"] 가 보이면 성공
```

> 윈도우 x64 PC면 플랫폼 문제 없음 (EKS 노드와 같은 amd64).
> 팀에 맥북(M1/M2/M3) 쓰는 사람이 있으면 그 사람만 `docker build --platform linux/amd64` 필수.

---

## 8장. 임시 스택 — Terraform 코드 전체 (1회 작성, 40분)

다이어그램의 AWS 안쪽 전부(VPC, 서브넷, NAT, EKS, RDS, Redis)가 이 폴더에서 나온다.
아래 5개 파일을 `infra\ephemeral\` 에 그대로 만든다.

### 8-1. `infra\ephemeral\main.tf`

```hcl
terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-<팀명>"          # 6-1의 버킷명
    key    = "ephemeral/terraform.tfstate"     # persistent와 장부 분리 — 핵심!
    region = "ap-northeast-2"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "ap-northeast-2" }

variable "db_password" {
  type      = string
  sensitive = true          # 실행 전 $env:TF_VAR_db_password 로 주입
}

variable "full_ha" {
  type    = bool
  default = true            # true = 다이어그램 그대로 / false = 절약 모드
}
```

### 8-2. `infra\ephemeral\vpc.tf` — 그림의 VPC + 서브넷 6개 + IGW + NAT

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "dib-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["ap-northeast-2a", "ap-northeast-2c"]        # 그림의 A / C

  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]    # Public subnet A/C: ALB, NAT
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24"]  # Private App subnet A/C: EKS 노드
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24"]  # Private Data subnet A/C: RDS, Redis

  enable_nat_gateway     = true
  single_nat_gateway     = !var.full_ha                # 절약: NAT 1개
  one_nat_gateway_per_az = var.full_ha                 # 그림: NAT Gateway A/C 2개

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }            # ALB 자리 표시
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
```

### 8-3. `infra\ephemeral\eks.tf` — 그림의 K8s 클러스터 + 워커 노드 + ALB컨트롤러용 IAM

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "dib-eks"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets              # 노드는 Private App 서브넷에만

  cluster_endpoint_public_access           = true      # 내 PC에서 kubectl 접속용
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    app = {
      instance_types = ["t3.medium"]
      min_size       = 2      # 그림의 EC2 #1/#2 — AZ 양쪽에 1대씩 자동 분산
      desired_size   = 2
      max_size       = 4      # 부하 시 여기까지 증설
    }
  }

  cluster_addons = { coredns = {}, kube-proxy = {}, vpc-cni = {} }
}

# ALB 컨트롤러가 쓸 IAM Role (IRSA) — 이걸 Terraform에 넣어두면 수작업 IAM이 0이 된다
module "lb_controller_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "dib-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
```

### 8-4. `infra\ephemeral\data.tf` — 그림의 RDS(Primary+Standby)와 Redis(Primary+Replica)

```hcl
# ── RDS PostgreSQL ──────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "dib-db"
  subnet_ids = module.vpc.database_subnets             # Private Data subnet A/C
}

resource "aws_security_group" "rds" {
  name   = "dib-rds-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]   # EKS 노드에서만 접근 허용
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

  multi_az               = var.full_ha                 # ← 그림의 Standby가 이 한 줄
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  apply_immediately   = true
}

# ── ElastiCache Redis ───────────────────────────────────────
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

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "dib-redis"
  description          = "cache + distributed lock + pubsub"

  engine    = "redis"
  node_type = "cache.t4g.micro"

  num_cache_clusters         = var.full_ha ? 2 : 1     # 2 = 그림의 Primary + Replica
  automatic_failover_enabled = var.full_ha
  multi_az_enabled           = var.full_ha

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}
```

### 8-5. `infra\ephemeral\outputs.tf`

```hcl
output "cluster_name"   { value = module.eks.cluster_name }
output "rds_endpoint"   { value = aws_db_instance.postgres.address }
output "redis_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "lb_role_arn"    { value = module.lb_controller_role.iam_role_arn }
output "vpc_id"         { value = module.vpc.vpc_id }
```

여기까지 만들었으면 8장 끝. **아직 apply 하지 않는다** — 띄우는 건 시연 날(9장).

---

## 9장. 시연 날 ① — 클러스터 띄우기 + 부트스트랩 (~30분)

### 9-1. 인프라 생성 (15~20분 소요, 커피 타임)

```powershell
cd $HOME\dib-infra\infra\ephemeral

# DB 비밀번호 생성 & 보관 (이 창을 닫으면 사라지니 메모)
$env:TF_VAR_db_password = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 24 | % {[char]$_})
$env:TF_VAR_db_password | Out-File $HOME\.dib-db-pass   # 백업

terraform init          # 처음 1회만 오래 걸림
terraform apply         # 미리보기 확인 후 yes — 약 15~20분
```

apply가 끝나면 그림에서 ALB 빼고 전부 존재한다. 콘솔 → EKS에서 dib-eks 확인 가능.

### 9-2. kubectl 연결

```powershell
aws eks update-kubeconfig --name dib-eks --region ap-northeast-2
kubectl get nodes -o wide
# 노드 2대, 서로 다른 AZ(2a/2c) → 그림의 EC2 #1/#2 완성
```

### 9-3. 부트스트랩 스크립트 — `scripts\bootstrap.ps1` (미리 만들어 두기)

```powershell
# scripts\bootstrap.ps1 — ALB 컨트롤러 + metrics-server + Secret
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..\infra\ephemeral

$LB_ROLE = terraform output -raw lb_role_arn
$VPC_ID  = terraform output -raw vpc_id
$RDS     = terraform output -raw rds_endpoint
$REDIS   = terraform output -raw redis_endpoint
$DB_PASS = Get-Content $HOME\.dib-db-pass

# 1. AWS Load Balancer Controller (Ingress → 실제 ALB 생성 담당)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
  -n kube-system `
  --set clusterName=dib-eks `
  --set region=ap-northeast-2 `
  --set vpcId=$VPC_ID `
  --set serviceAccount.create=true `
  --set serviceAccount.name=aws-load-balancer-controller `
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LB_ROLE"

# 2. metrics-server (HPA의 눈)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 3. 접속 정보 Secret
kubectl delete secret dib-secrets --ignore-not-found
kubectl create secret generic dib-secrets `
  --from-literal=DB_URL="jdbc:postgresql://${RDS}:5432/auction" `
  --from-literal=DB_PASSWORD="$DB_PASS" `
  --from-literal=REDIS_HOST="$REDIS" `
  --from-literal=KAFKA_SERVERS="kafka-0.kafka:9092" `
  --from-literal=JWT_SECRET="$(-join ((65..90)+(97..122)+(48..57) | Get-Random -Count 48 | % {[char]$_}))" `
  --from-literal=AI_SERVER_URL="https://<온프렘-AI-주소>" `
  --from-literal=AI_API_KEY="<온프렘과-맞춘-키>"

Write-Host "`n부트스트랩 완료. 다음: scripts\deploy.ps1" -ForegroundColor Green
```

실행:

```powershell
cd $HOME\dib-infra
.\scripts\bootstrap.ps1
kubectl get pods -n kube-system | Select-String "load-balancer"   # Running 2개면 성공
```

---

## 10장. 시연 날 ② — 앱 배포 + ALB 주소 받기 (~15분)

### 10-1. K8s 매니페스트 4개 (미리 만들어 두기)

**`infra\k8s\kafka.yaml`** — 그림의 [Kafka Cluster (K8s StatefulSet)]

```yaml
apiVersion: v1
kind: Service
metadata: { name: kafka }
spec:
  clusterIP: None                  # headless — 파드 주소가 kafka-0.kafka 로 고정됨
  selector: { app: kafka }
  ports: [{ port: 9092 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: kafka }
spec:
  serviceName: kafka
  replicas: 1
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
            - { name: KAFKA_ADVERTISED_LISTENERS, value: "PLAINTEXT://kafka-0.kafka:9092" }
            - { name: KAFKA_CONTROLLER_LISTENER_NAMES, value: "CONTROLLER" }
            - { name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, value: "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" }
            - { name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR, value: "1" }
            - { name: KAFKA_AUTO_CREATE_TOPICS_ENABLE, value: "true" }
```

**`infra\k8s\spring.yaml`** — 그림의 [Spring Boot Pod] (A/C 양쪽 분산)

```yaml
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
      topologySpreadConstraints:                 # Pod를 AZ A/C에 고르게
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: dib-backend } }
      containers:
        - name: app
          image: <계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com/dib-backend:latest   # ← 계정ID 교체!
          ports: [{ containerPort: 8080 }]
          envFrom: [{ secretRef: { name: dib-secrets } }]
          resources:
            requests: { cpu: "500m", memory: "768Mi" }    # 없으면 HPA가 계산을 못 함
            limits:   { memory: "1280Mi" }
          readinessProbe:
            httpGet: { path: /actuator/health, port: 8080 }
            initialDelaySeconds: 25
          livenessProbe:
            httpGet: { path: /actuator/health, port: 8080 }
            initialDelaySeconds: 45
          lifecycle:
            preStop: { exec: { command: ["sh","-c","sleep 10"] } }   # WS 연결 정리 시간
---
apiVersion: v1
kind: Service
metadata: { name: dib-backend }
spec:
  selector: { app: dib-backend }
  ports: [{ port: 80, targetPort: 8080 }]
```

**`infra\k8s\ingress.yaml`** — 이걸 apply하는 순간 그림의 [ALB]가 실제로 생긴다

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dib-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
    # ↑ WebSocket 필수 — 기본 60초면 경매 화면이 1분마다 끊긴다
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: dib-backend, port: { number: 80 } } }
```

**`infra\k8s\hpa.yaml`**

```yaml
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
    scaleDown: { stabilizationWindowSeconds: 120 }
```

### 10-2. 배포 스크립트 — `scripts\deploy.ps1`

```powershell
# scripts\deploy.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

kubectl apply -f infra\k8s\kafka.yaml
kubectl rollout status statefulset/kafka --timeout=180s

kubectl apply -f infra\k8s\spring.yaml
kubectl rollout status deployment/dib-backend --timeout=300s

kubectl apply -f infra\k8s\ingress.yaml
kubectl apply -f infra\k8s\hpa.yaml

Write-Host "`nALB 주소가 뜰 때까지 2~3분 대기..." -ForegroundColor Yellow
Start-Sleep -Seconds 150
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Write-Host "`n===== API 주소: http://$ALB =====" -ForegroundColor Green
Write-Host "이 주소를 Kotlin 앱의 BASE_URL에 넣고 빌드하세요"
```

```powershell
.\scripts\deploy.ps1
```

### 10-3. 동작 확인

```powershell
kubectl get pods -o wide       # 전부 Running, 노드가 2a/2c 섞여 있는지
kubectl get hpa                # TARGETS가 3%/60% 처럼 숫자로 (unknown이면 metrics-server 문제)
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl.exe "http://$ALB/actuator/health"     # {"status":"UP"} 이면 전체 개통!
```

`{"status":"UP"}` 이 떴다 = **다이어그램의 모든 박스가 실제로 돌아가는 상태.**
Kotlin 앱 BuildConfig의 BASE_URL만 이 주소로 바꿔 빌드하면 폰에서 접속된다.

---

## 11장. 시연 날 ③ — 스모크 테스트 (15분)

폰 2대(또는 폰+에뮬레이터)로 아래 순서 그대로. 각 줄이 그림의 흐름 번호를 검증한다.

| # | 하는 것 | 확인되는 것 |
|---|---|---|
| 1 | 회원가입 → 로그인 | ① JWT 발급/검증 |
| 2 | 상품 등록 (사진 포함) | S3 업로드 + ⑦ Kafka 등록 이벤트 |
| 3 | 상품 목록 연속 2번 조회 | ④ 2번째가 눈에 띄게 빠름 = Redis 캐시 히트 |
| 4 | 두 폰에서 같은 상품 동시 입찰 | ⑤ 분산 락 — 한쪽 성공, 한쪽 "현재가 갱신" 안내 |
| 5 | 입찰 안 한 폰의 화면 | ⑥ WebSocket으로 현재가 실시간 갱신 |
| 6 | 낙찰 처리 | ⑧ 알림톡 도착 + AI 서버 로그에 분석 요청 |

부하 테스트 (선택, HPA 시연용):

```powershell
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
$env:BASE_URL = "http://$ALB"
k6 run load-test\bid-scenario.js
# 다른 창에서: kubectl get hpa -w   ← Pod 2→4→6 늘어나는 장면을 화면 녹화 (포트폴리오 자료!)
```

---

## 12장. 시연 끝 — 철거 (25분, 순서 엄수)

### `scripts\teardown.ps1`

```powershell
# scripts\teardown.ps1 — ★ Ingress 먼저, Terraform은 그다음
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot\..

# 1. K8s가 만든 AWS 리소스(ALB) 먼저 삭제 유발
kubectl delete ingress --all --ignore-not-found
kubectl delete -f infra\k8s\ --ignore-not-found
Write-Host "ALB 삭제 대기 90초..." ; Start-Sleep -Seconds 90

# 2. Terraform 스택 삭제 (~15분)
Set-Location infra\ephemeral
terraform destroy -auto-approve

# 3. 삭제 검증 — 전부 [] 또는 빈 값이어야 함
Set-Location ..\..
Write-Host "`n===== 삭제 검증 =====" -ForegroundColor Yellow
aws eks list-clusters --region ap-northeast-2 --query "clusters"
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws elasticache describe-replication-groups --query "ReplicationGroups[].ReplicationGroupId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --query "Addresses[].PublicIp"
Write-Host "전부 비어 있으면 과금 요소 0. ECR/S3(상시 스택)만 남은 게 정상" -ForegroundColor Green
```

```powershell
.\scripts\teardown.ps1
```

**왜 Ingress 먼저인가**: ALB는 Terraform이 아니라 K8s 컨트롤러가 만들었다.
Terraform 장부에 없는 물건이라 destroy가 못 지우고, 그 ALB가 서브넷을 물고 있어서
VPC 삭제가 실패한다 → 잔해가 남아 계속 과금. 이 순서 하나가 이 문서에서 제일 중요하다.

다음 날 콘솔 → Cost Explorer에서 그날 비용이 $5 이하인지 확인하는 것까지가 철거다.

---

## 13장. 윈도우에서 자주 터지는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `docker: error during connect` | Docker Desktop이 안 켜져 있음 — 실행하고 Engine running 확인 |
| WSL 설치 실패 "가상화" 에러 | BIOS에서 VT-x/SVM Enable (2-1 참고) |
| `.ps1 실행할 수 없으므로` | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (4장) |
| winget 설치 후 명령 인식 안 됨 | PowerShell 창 재시작 (PATH 갱신) |
| `curl` 결과가 이상함 | PowerShell의 curl은 별칭 — **`curl.exe`** 로 실행 |
| terraform apply 중 `AccessDenied` | aws configure의 키가 1-2의 IAM 사용자(Admin) 것인지 확인 |
| kubectl `Unauthorized` | `aws eks update-kubeconfig ...` 재실행 (9-2) |
| Ingress ADDRESS 빈칸 | ALB 컨트롤러 확인: `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA `<unknown>` | metrics-server 미설치(9-3) 또는 spring.yaml의 resources.requests 누락 |
| Pod `ImagePullBackOff` | spring.yaml의 이미지 주소에 <계정ID> 그대로 남아 있음 — 교체했는지 확인 |
| RDS 연결 실패 | Secret의 DB_URL이 최신 output인지: `terraform output rds_endpoint` 와 비교 |
| Redis `READONLY` 에러 | Replica 주소에 쓰기 시도 — Secret의 REDIS_HOST가 primary_endpoint인지 확인 |
| WebSocket 1분마다 끊김 | ingress.yaml의 idle_timeout=3600 annotation 누락 |
| destroy가 VPC에서 멈춤 | Ingress 안 지우고 destroy함 — 콘솔 EC2→로드밸런서에서 잔여 ALB 수동 삭제 후 재실행 |

---

## 부록. 시연 날 치트시트 (이것만 보고 진행)

```powershell
# ===== 띄우기 (T+0) =====
cd $HOME\dib-infra\infra\ephemeral
$env:TF_VAR_db_password = Get-Content $HOME\.dib-db-pass
terraform apply -auto-approve            # ~20분

# ===== 부트스트랩 + 배포 (T+20분) =====
cd $HOME\dib-infra
aws eks update-kubeconfig --name dib-eks --region ap-northeast-2
.\scripts\bootstrap.ps1
.\scripts\deploy.ps1                     # 끝나면 ALB 주소 출력됨

# ===== 확인 (T+30분) =====
kubectl get pods -o wide
$ALB = kubectl get ingress dib-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl.exe "http://$ALB/actuator/health"   # {"status":"UP"}

# ===== 철거 (종료 30분 전) =====
.\scripts\teardown.ps1                   # 검증 출력까지 확인
```

준비(1~8장)가 끝난 상태라면, 시연 날 실제로 치는 명령은 위 4블록이 전부다.
