# ---------------------------------------------------------------- security groups
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Interne load balancer voor de SOAR"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description = "Interne HTTP vanaf het platform"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.platform_vpc_cidr]
  }

  egress {
    description = "Alleen naar de SOAR-taken"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.platform_app_cidrs
  }

  tags = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "soar" {
  name        = "${local.name}-soar"
  description = "SOAR-taken op ECS Fargate"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description     = "Webhook en health checks vanaf de ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Uitgaand voor AWS-APIs, database en internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-soar" }
}

resource "aws_security_group" "observability" {
  name        = "${local.name}-observability"
  description = "Grafana, Loki en de syslog-ontvanger"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description = "Syslog vanaf de bewaakte servers"
    from_port   = 6514
    to_port     = 6514
    protocol    = "tcp"
    cidr_blocks = [var.workload_vpc_cidr]
  }

  ingress {
    description = "Grafana, alleen binnen het platform"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.platform_vpc_cidr]
  }

  ingress {
    description = "Loki push-API, alleen binnen het platform"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.platform_vpc_cidr, var.workload_vpc_cidr]
  }

  egress {
    description = "Uitgaand voor updates, S3 en AWS-APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-observability" }
}

resource "aws_security_group" "workload" {
  name        = "${local.name}-workload"
  description = "Bewaakte servers in de Workload-VPC"
  vpc_id      = aws_vpc.workload.id

  ingress {
    description = "Ansible over SSH vanaf de runner"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${local.runner_private_ip}/32"]
  }

  ingress {
    description = "Ansible over WinRM HTTPS vanaf de runner"
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = ["${local.runner_private_ip}/32"]
  }

  egress {
    description = "Uitgaand voor syslog, metrics, updates en SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-workload" }
}

resource "aws_security_group" "runner" {
  name        = "${local.name}-runner"
  description = "Self-hosted GitHub Actions runner"
  vpc_id      = aws_vpc.platform.id

  egress {
    description = "Uitgaand voor GitHub, AWS en Ansible"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-runner" }
}

resource "aws_security_group" "aurora" {
  name        = "${local.name}-aurora"
  description = "Aurora Serverless v2 voor de audit"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description     = "PostgreSQL vanaf de SOAR"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.soar.id]
  }

  egress {
    description = "Standaard uitgaand verkeer"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-aurora" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda"
  description = "Gesimuleerde firewall-API"
  vpc_id      = aws_vpc.platform.id

  egress {
    description = "Uitgaand naar DynamoDB via de gateway-endpoint"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-lambda" }
}
