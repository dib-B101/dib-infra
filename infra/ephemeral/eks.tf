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
      instance_types = ["t3.medium"]
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
