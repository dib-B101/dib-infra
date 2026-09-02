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

variable "full_ha" {
  type    = bool
  default = true # true = 다이어그램 그대로(NAT 2, RDS Multi-AZ, Redis Replica)
                 # false = 절약 모드(NAT 1, 단일 RDS/Redis) — 개인 테스트용
}
