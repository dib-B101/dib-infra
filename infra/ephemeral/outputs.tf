output "cluster_name"   { value = module.eks.cluster_name }
output "rds_endpoint"   { value = aws_db_instance.postgres.address }
output "redis_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "lb_role_arn"    { value = module.lb_controller_role.iam_role_arn }
output "vpc_id"         { value = module.vpc.vpc_id }
