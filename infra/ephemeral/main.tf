############################################################
# 임시 스택 — 시연/부하테스트 때만 생성하고 끝나면 destroy
# 생성: terraform apply   삭제: scripts/teardown.ps1 (★ 직접 destroy 금지)
############################################################

terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket = "dib-tfstate-b101a" # persistent와 같은 버킷, key만 다름
    key    = "ephemeral/terraform.tfstate"
    region = "ap-northeast-2"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "ap-northeast-2" }

variable "db_password" {
  type      = string
  sensitive = true # 실행 전 PowerShell에서: $env:TF_VAR_db_password = "..."
}

variable "node_instance_type" {
  type        = string
  default     = "t3.large" # AI 까지 같은 클러스터에 올리므로 8GB. AI 를 빼면 t3.medium 으로 충분
  description = "EKS 워커 노드 타입"
}

variable "product_images_bucket" {
  type        = string
  default     = "dib-product-images-b101a" # persistent 스택의 aws_s3_bucket.product_images 와 같은 이름
  description = "상품 이미지 버킷. persistent 에서 이름을 바꿨으면 여기도 같이 바꾼다"
}

variable "full_ha" {
  type    = bool
  default = true # true = 다이어그램 그대로(NAT 2, RDS Multi-AZ, Redis Replica)
                 # false = 절약 모드(NAT 1, 단일 RDS/Redis) — 개인 테스트용
}
