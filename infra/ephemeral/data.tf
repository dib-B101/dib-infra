############################################################
# 다이어그램: RDS PostgreSQL Primary→Standby(Multi-AZ)
#            ElastiCache Redis Primary→Replica
# 전부 Private Data subnet A/C에 배치, EKS 노드에서만 접근 가능
############################################################

# ── RDS PostgreSQL ─────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "dib-db"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_security_group" "rds" {
  name   = "dib-rds-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id] # EKS 노드에서만
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

  multi_az               = var.full_ha # ← 다이어그램의 Standby가 이 한 줄
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  apply_immediately   = true
}

# ── ElastiCache Redis ──────────────────────────────────────
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

  num_cache_clusters         = var.full_ha ? 2 : 1 # 2 = 다이어그램의 Primary + Replica
  automatic_failover_enabled = var.full_ha
  multi_az_enabled           = var.full_ha

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}
