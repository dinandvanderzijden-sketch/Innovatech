locals {
  container_name = "nginx"
}

################ ECR ################
resource "aws_ecr_repository" "web" {
  name                 = "${var.name}-web"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "web" {
  repository = aws_ecr_repository.web.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Bewaar de laatste 15 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}

################ SECURITY GROUPS ################
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web"
  description = "NGINX Fargate tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP from internet (HTTPS vereist een domein + ACM-certificaat)"
}

resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  for_each = toset(var.test_access_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
  description       = "Blue-green test listener"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_to_db" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = var.db_cidr
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "ECR, CloudWatch Logs, Secrets Manager via NAT in de Hub"
}

################ ALB + TARGET GROUPS (blue/green) ################
resource "aws_lb" "web" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "blue" {
  name                 = "${var.name}-blue"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "green" {
  name                 = "${var.name}-green"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy wisselt de target group bij elke deployment; Terraform mag dat niet terugdraaien.
  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.web.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

################ IAM ################
resource "aws_iam_role" "task_execution" {
  name = "${var.name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# De execution role haalt de secrets op bij het starten van de taak (injectie als env-variabele).
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

################ ECS ################
resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${var.name}"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "web" {
  name = "${var.name}-cluster"
}

resource "aws_ecs_task_definition" "web" {
  family                   = "${var.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.container_cpu)
  memory                   = tostring(var.container_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = local.container_name
    image        = var.container_image
    essential    = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]

    environment = [
      { name = "DB_HOST", value = var.db_endpoint },
      { name = "DB_PORT", value = "3306" }
    ]

    secrets = [
      { name = "DB_USERNAME", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.web.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "nginx"
      }
    }
  }])
}

resource "aws_ecs_service" "web" {
  name            = "${var.name}-web"
  cluster         = aws_ecs_cluster.web.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.min_tasks
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  health_check_grace_period_seconds = 30

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = local.container_name
    container_port   = 80
  }

  # Na de eerste apply beheren CodeDeploy (image/task definition, target group) en
  # Auto Scaling (aantal taken) deze waarden. Terraform blijft er vanaf.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  depends_on = [aws_lb_listener.prod, aws_lb_listener.test]
}

################ AUTO SCALING (REQ-04) ################
resource "aws_appautoscaling_target" "web" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.web.name}/${aws_ecs_service.web.name}"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks
}

# CPU > 70% gedurende 5 minuten: +2 taken
resource "aws_appautoscaling_policy" "scale_out" {
  name               = "${var.name}-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.web.service_namespace
  scalable_dimension = aws_appautoscaling_target.web.scalable_dimension
  resource_id        = aws_appautoscaling_target.web.resource_id

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = 2
      metric_interval_lower_bound = 0
    }
  }
}

# CPU < 20% gedurende 10 minuten: terug naar het minimum
resource "aws_appautoscaling_policy" "scale_in" {
  name               = "${var.name}-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.web.service_namespace
  scalable_dimension = aws_appautoscaling_target.web.scalable_dimension
  resource_id        = aws_appautoscaling_target.web.resource_id

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = var.min_tasks
      metric_interval_upper_bound = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "${var.name}-scale-out-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 70
  alarm_actions       = [aws_appautoscaling_policy.scale_out.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.web.name
    ServiceName = aws_ecs_service.web.name
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${var.name}-scale-in-cpu-low"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 10
  comparison_operator = "LessThanThreshold"
  threshold           = 20
  alarm_actions       = [aws_appautoscaling_policy.scale_in.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.web.name
    ServiceName = aws_ecs_service.web.name
  }
}

################ BLUE/GREEN DEPLOYMENT (CodeDeploy) ################
resource "aws_iam_role" "codedeploy" {
  name = "${var.name}-codedeploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "web" {
  name             = "${var.name}-web"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "web" {
  app_name               = aws_codedeploy_app.web.name
  deployment_group_name  = "${var.name}-web-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 30
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.web.name
    service_name = aws_ecs_service.web.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.prod.arn]
      }

      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }

      target_group {
        name = aws_lb_target_group.blue.name
      }

      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }
}
