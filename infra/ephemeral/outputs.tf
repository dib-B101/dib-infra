output "cluster_name"   { value = module.eks.cluster_name }
output "rds_endpoint"   { value = aws_db_instance.postgres.address }
output "redis_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "lb_role_arn"    { value = module.lb_controller_role.iam_role_arn }
output "app_role_arn"   { value = module.app_role.iam_role_arn }
output "vpc_id"         { value = module.vpc.vpc_id }

# 카카오 REST OAuth 가 앱으로 돌아올 HTTPS App Link 주소(kakao_callback.tf 의 CloudFront).
# 스택을 새로 만들 때마다 도메인이 바뀌므로 bootstrap 이 이 값으로 KAKAO_REDIRECT_URIS 를 채운다
output "kakao_callback_domain" {
  value = aws_cloudfront_distribution.kakao_callback.domain_name
}

output "kakao_redirect_uri" {
  value = "https://${aws_cloudfront_distribution.kakao_callback.domain_name}/oauth/kakao/callback"
}

output "password_reset_url" {
  value = "https://${aws_cloudfront_distribution.kakao_callback.domain_name}/password/reset"
}
