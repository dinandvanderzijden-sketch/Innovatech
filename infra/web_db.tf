# ---------------------------------------------------------------- web-database
# De website is een echt database-backed gastenboek. Webdata staat bewust in
# een eigen Aurora-cluster, los van de auditdatabase van de SOAR:
#
#   * de SOAR mag niet bij webdata, en andersom;
#   * een storing of restore raakt maar één van de twee;
#   * de webdatabase schaalt naar 0 ACU als er niemand kijkt.
#
# Eén instantie is een bewuste kostenkeuze (net als `db_multi_az = false` in
# CS1). De auditdatabase houdt wel twee instanties in twee zones.

resource "random_password" "web_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "web_db" {
  name                    = "${local.name}/web-db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "web_db" {
  secret_id = aws_secretsmanager_secret.web_db.id
  secret_string = jsonencode({
    username = "web_admin"
    password = random_password.web_db.result
  })
}

resource "aws_security_group" "web_db" {
  name        = "${local.name}-web-db"
  description = "Aurora voor de websites"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description = "PostgreSQL vanaf de webservers"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.workload_vpc_cidr]
  }

  egress {
    description = "Standaard uitgaand verkeer"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-web-db" }
}

resource "aws_rds_cluster" "web" {
  cluster_identifier = "${local.name}-web-aurora"
  engine             = "aurora-postgresql"
  database_name      = "web"
  master_username    = "web_admin"
  master_password    = random_password.web_db.result

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.web_db.id]

  storage_encrypted       = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  tags = { Name = "${local.name}-web-aurora" }
}

resource "aws_rds_cluster_instance" "web" {
  identifier         = "${local.name}-web-aurora-1"
  cluster_identifier = aws_rds_cluster.web.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.web.engine
  engine_version     = aws_rds_cluster.web.engine_version
  availability_zone  = local.azs[0]

  tags = { Name = "${local.name}-web-aurora-1" }
}

# ---------------------------------------------------------------- app-code
resource "aws_s3_object" "webapp" {
  bucket       = aws_s3_bucket.artifacts.id
  key          = "webapp/app.py"
  source       = "${path.module}/../webapp/app.py"
  etag         = filemd5("${path.module}/../webapp/app.py")
  content_type = "text/x-python"
}

# ---------------------------------------------------------------- parameters
resource "aws_ssm_parameter" "web_db_host" {
  name  = "${local.param_prefix}/config/web_db_host"
  type  = "String"
  value = aws_rds_cluster.web.endpoint
}

resource "aws_ssm_parameter" "web_db_name" {
  name  = "${local.param_prefix}/config/web_db_name"
  type  = "String"
  value = "web"
}

resource "aws_ssm_parameter" "web_db_secret" {
  name  = "${local.param_prefix}/config/web_db_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.web_db.arn
}
