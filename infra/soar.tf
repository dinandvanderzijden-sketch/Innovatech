# ---------------------------------------------------------------- image
resource "aws_ecr_repository" "soar" {
  name                 = "${local.name}-soar"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${local.name}-soar" }
}

resource "aws_ecr_lifecycle_policy" "soar" {
  repository = aws_ecr_repository.soar.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Bewaar de laatste 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------- wachtrijen
resource "aws_sqs_queue" "events_dlq" {
  name                      = "${local.name}-soar-events-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.name}-soar-events"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "events_queue" {
  statement {
    sid       = "AllowEventBridge"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.alarm.arn,
        aws_cloudwatch_event_rule.finding.arn,
      ]
    }
  }
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy    = data.aws_iam_policy_document.events_queue.json
}

# ---------------------------------------------------------------- tabellen
resource "aws_dynamodb_table" "dedupe" {
  name         = "${local.name}-soar-dedupe"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "correlation_id"

  attribute {
    name = "correlation_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = { Name = "${local.name}-soar-dedupe" }
}

resource "aws_dynamodb_table" "blocked_ips" {
  name         = "${local.name}-blocked-ips"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ip"

  attribute {
    name = "ip"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = { Name = "${local.name}-blocked-ips" }
}

# ---------------------------------------------------------------- firewall-API (simulatie)
data "archive_file" "firewall_api" {
  type        = "zip"
  source_file = "${path.module}/../lambda/firewall_api.py"
  output_path = "${path.module}/build/firewall_api.zip"
}

resource "aws_cloudwatch_log_group" "firewall_lambda" {
  name              = "/aws/lambda/${local.name}-firewall-api"
  retention_in_days = 30
}

resource "aws_lambda_function" "firewall_api" {
  function_name    = "${local.name}-firewall-api"
  role             = aws_iam_role.firewall_lambda.arn
  runtime          = "python3.12"
  handler          = "firewall_api.handler"
  filename         = data.archive_file.firewall_api.output_path
  source_code_hash = data.archive_file.firewall_api.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.blocked_ips.name
    }
  }

  vpc_config {
    subnet_ids         = [for k, v in local.platform_subnets : aws_subnet.platform[k].id if v.tier == "app"]
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [
    aws_iam_role_policy.firewall_lambda,
    aws_iam_role_policy_attachment.firewall_lambda_vpc,
    aws_cloudwatch_log_group.firewall_lambda,
  ]

  tags = { Name = "${local.name}-firewall-api" }
}

# ---------------------------------------------------------------- load balancer
resource "aws_lb" "soar" {
  name               = "${local.name}-soar"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for k, v in local.platform_subnets : aws_subnet.platform[k].id if v.tier == "dmz"]

  idle_timeout               = 60
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = { Name = "${local.name}-soar" }
}

resource "aws_lb_target_group" "soar" {
  name        = "${local.name}-soar"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.platform.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = { Name = "${local.name}-soar" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.soar.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.soar.arn
  }
}

# ---------------------------------------------------------------- ECS
resource "aws_cloudwatch_log_group" "soar" {
  name              = "/aws/ecs/${local.name}-soar"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "soar" {
  name = "${local.name}-soar"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "soar" {
  family                   = "${local.name}-soar"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.soar_cpu
  memory                   = var.soar_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.soar_task.arn

  container_definitions = jsonencode([
    {
      name      = "soar"
      image     = "${aws_ecr_repository.soar.repository_url}:${var.soar_image_tag}"
      essential = true

      portMappings = [{
        containerPort = 8080
        protocol      = "tcp"
      }]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "QUEUE_URL", value = aws_sqs_queue.events.url },
        { name = "DEDUPE_TABLE", value = aws_dynamodb_table.dedupe.name },
        { name = "AUDIT_BUCKET", value = aws_s3_bucket.audit.bucket },
        { name = "QUARANTINE_PREFIX", value = "quarantine" },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.alerts.arn },
        { name = "FIREWALL_FUNCTION_NAME", value = aws_lambda_function.firewall_api.function_name },
        { name = "DB_HOST", value = aws_rds_cluster.soar.endpoint },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = "soar" },
        { name = "METRIC_NAMESPACE", value = "CS2/SOAR" },
        { name = "SERVICE_NAME", value = "${local.name}-soar" },
        { name = "RULES_PATH", value = "/app/rules.json" },
      ]

      secrets = [
        { name = "DB_USER", valueFrom = "${aws_secretsmanager_secret.db.arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.soar.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "soar"
        }
      }
    }
  ])

  tags = { Name = "${local.name}-soar" }
}

resource "aws_ecs_service" "soar" {
  name            = "${local.name}-soar"
  cluster         = aws_ecs_cluster.soar.id
  task_definition = aws_ecs_task_definition.soar.arn
  desired_count   = var.soar_desired_count
  launch_type     = "FARGATE"

  platform_version = "LATEST"
  propagate_tags   = "SERVICE"

  network_configuration {
    subnets          = [for k, v in local.platform_subnets : aws_subnet.platform[k].id if v.tier == "app"]
    security_groups  = [aws_security_group.soar.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.soar.arn
    container_name   = "soar"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.soar_task,
    aws_iam_role_policy.ecs_execution_secrets,
  ]

  tags = { Name = "${local.name}-soar" }
}

# ---------------------------------------------------------------- EventBridge
resource "aws_cloudwatch_event_rule" "alarm" {
  name        = "${local.name}-alarm-to-soar"
  description = "Stuurt CloudWatch-alarmen naar de SOAR"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "alarm_sqs" {
  rule = aws_cloudwatch_event_rule.alarm.name
  arn  = aws_sqs_queue.events.arn
}

# Eigen beveiligingsbevindingen (bijvoorbeeld uit een demo- of testbron).
resource "aws_cloudwatch_event_rule" "finding" {
  name        = "${local.name}-finding-to-soar"
  description = "Stuurt eigen beveiligingsbevindingen naar de SOAR"

  event_pattern = jsonencode({
    source      = ["cs2.demo"]
    detail-type = ["CS2 Security Finding"]
  })
}

resource "aws_cloudwatch_event_target" "finding_sqs" {
  rule = aws_cloudwatch_event_rule.finding.name
  arn  = aws_sqs_queue.events.arn
}
