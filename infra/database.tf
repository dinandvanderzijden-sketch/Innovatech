resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name}-aurora"
  subnet_ids = [for k, v in local.platform_subnets : aws_subnet.platform[k].id if v.tier == "data"]

  tags = { Name = "${local.name}-aurora" }
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "soar_admin"
    password = random_password.db.result
  })
}

resource "aws_rds_cluster" "soar" {
  cluster_identifier = "${local.name}-aurora"
  engine             = "aurora-postgresql"
  database_name      = "soar"
  master_username    = "soar_admin"
  master_password    = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  storage_encrypted       = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  enable_http_endpoint    = false
  copy_tags_to_snapshot   = true
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  tags = { Name = "${local.name}-aurora" }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name}-aurora-1"
  cluster_identifier = aws_rds_cluster.soar.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.soar.engine
  engine_version     = aws_rds_cluster.soar.engine_version
  availability_zone  = local.azs[0]
  promotion_tier     = 0

  tags = { Name = "${local.name}-aurora-1" }
}

# Tweede instantie in de andere zone: Aurora schakelt automatisch over.
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${local.name}-aurora-2"
  cluster_identifier = aws_rds_cluster.soar.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.soar.engine
  engine_version     = aws_rds_cluster.soar.engine_version
  availability_zone  = local.azs[1]
  promotion_tier     = 1

  tags = { Name = "${local.name}-aurora-2" }
}
