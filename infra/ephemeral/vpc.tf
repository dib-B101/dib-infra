############################################################
# 다이어그램: VPC(10.0.0.0/16) + Public/App/Data 서브넷 6개
#            + Internet Gateway + NAT Gateway A/C
############################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "dib-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["ap-northeast-2a", "ap-northeast-2c"] # 다이어그램의 A / C

  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]   # Public subnet A/C: ALB, NAT
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24"] # Private App subnet A/C: EKS 노드
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24"] # Private Data subnet A/C: RDS, Redis

  enable_nat_gateway     = true
  single_nat_gateway     = !var.full_ha # 절약: NAT 1개
  one_nat_gateway_per_az = var.full_ha  # 그림 그대로: NAT Gateway A/C 2개

  # ALB 컨트롤러가 서브넷을 찾는 태그 — 지우면 ALB가 안 생김 (최다 빈출 함정)
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
