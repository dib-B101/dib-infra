############################################################
# 다이어그램: Kubernetes Cluster + EC2 #1/#2 (Worker Node)
# + ALB 컨트롤러용 IAM Role(IRSA) — 수작업 IAM 0을 위해 코드화
############################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "dib-eks"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # 노드는 Private App 서브넷에만

  cluster_endpoint_public_access           = true # 내 PC에서 kubectl 접속용
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    app = {
      # AI(torch·transformers)가 같은 클러스터에 올라간다. t3.medium(4GB)에는
      # 백엔드 2대 + Kafka + AI 가 같이 안 들어가서 t3.large(8GB)로 올렸다.
      # AI 를 외부로 빼면 t3.medium 으로 되돌려도 된다
      instance_types = [var.node_instance_type]
      min_size       = 2 # 다이어그램의 EC2 #1/#2 — AZ 양쪽에 자동 분산
      desired_size   = 2
      max_size       = 4 # 부하 시 여기까지 증설
    }
  }

  cluster_addons = { coredns = {}, kube-proxy = {}, vpc-cni = {} }
}

# ALB 컨트롤러(Ingress→실제 ALB 생성)가 쓸 IAM Role
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

# 백엔드 Pod(ServiceAccount default:dib-backend)가 상품 이미지 버킷에만 접근하는 IAM Role.
# 액세스 키를 Secret 에 넣지 않기 위해 IRSA 로 받는다.
resource "aws_iam_policy" "product_images" {
  name        = "dib-product-images"
  description = "상품 이미지 버킷 객체 읽기/쓰기/삭제"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.product_images_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.product_images_bucket}"
      }
    ]
  })
}

module "app_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "dib-backend-app"
  role_policy_arns = {
    product_images = aws_iam_policy.product_images.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:dib-backend"]
    }
  }
}
