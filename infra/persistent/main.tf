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

output "s3_bucket"   { value = aws_s3_bucket.product_images.bucket }
output "ecr_backend" { value = aws_ecr_repository.backend.repository_url }
