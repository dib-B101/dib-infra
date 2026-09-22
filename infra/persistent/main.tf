############################################################
# 상시 스택 — ECR(이미지 저장소) + S3(상품 이미지)
# 프로젝트 끝날 때까지 destroy 하지 않는다. 월 비용 $1 미만.
############################################################

terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-b101a" # ★ 6-1에서 만든 버킷명 (전 세계 유일해야 함 — 겹치면 이름 바꾸기)
    key    = "persistent/terraform.tfstate"
    region = "ap-northeast-2"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "ap-northeast-2" }

# ── 다이어그램의 [S3 Storage: 상품 이미지] ─────────────────
resource "aws_s3_bucket" "product_images" {
  bucket        = "dib-product-images-b101a" # ★ 겹치면 이름 바꾸기
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

# ── 도커 이미지 저장소 ────────────────────────────────────
resource "aws_ecr_repository" "backend" {
  name         = "dib-backend"
  force_delete = true
}

# AI(FastAPI). torch·transformers 가 들어가 이미지가 수 GB 라 푸시가 오래 걸린다 —
# 시연 전날 미리 밀어 두면 당일 이 단계가 사라진다
resource "aws_ecr_repository" "ai" {
  name         = "dib-ai"
  force_delete = true
}

# 관리자 웹(nginx 정적). 수십 MB 라 부담 없다
resource "aws_ecr_repository" "admin_web" {
  name         = "dib-admin-web"
  force_delete = true
}

# 이미지를 매번 latest 로 덮어써서 태그 없는 레이어가 쌓인다. 30일 지난 건 자동 삭제
resource "aws_ecr_lifecycle_policy" "untagged" {
  for_each = {
    backend   = aws_ecr_repository.backend.name
    ai        = aws_ecr_repository.ai.name
    admin_web = aws_ecr_repository.admin_web.name
  }
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "태그 없는 이미지 30일 후 삭제"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

output "s3_bucket"     { value = aws_s3_bucket.product_images.bucket }
output "ecr_backend"   { value = aws_ecr_repository.backend.repository_url }
output "ecr_ai"        { value = aws_ecr_repository.ai.repository_url }
output "ecr_admin_web" { value = aws_ecr_repository.admin_web.repository_url }
output "ecr_registry"  { value = split("/", aws_ecr_repository.backend.repository_url)[0] }
