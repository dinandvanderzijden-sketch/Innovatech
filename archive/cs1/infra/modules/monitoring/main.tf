# Observability (REQ-05): Prometheus + Grafana op EC2 in het management-subnet.
# YACE (CloudWatch -> Prometheus exporter) haalt ECS-, ALB- en RDS-metrics op, want node_exporter
# werkt niet op Fargate. Alarmen met e-mailnotificatie lopen via CloudWatch + SNS.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

################ SNS + ALARMEN ################
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Metriek: CPU ECS > 70% gedurende 5 minuten
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 70
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
}

# Metriek: geheugen ECS > 80%
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name}-memory-high"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
}

# Metriek: HTTP 5xx > 1% van het verkeer (1 minuut)
resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${var.name}-alb-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * FILL(errors, 0) / requests"
    label       = "5xx %"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }
}

# Metriek: responstijd > 500 ms gemiddeld (3 minuten)
resource "aws_cloudwatch_metric_alarm" "latency_high" {
  alarm_name          = "${var.name}-target-response-time"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

# Metriek: database CPU > 85% gedurende 5 minuten
resource "aws_cloudwatch_metric_alarm" "db_cpu_high" {
  alarm_name          = "${var.name}-db-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

################ PROMETHEUS + GRAFANA EC2 ################
resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring"
  description = "Prometheus/Grafana: geen inkomend verkeer, toegang via SSM port-forward"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "monitoring_all" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "monitoring" {
  name = "${var.name}-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "cloudwatch-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "tag:GetResources",
        "iam:ListAccountAliases",
        "ec2:DescribeTransitGatewayAttachments",
        "ec2:DescribeSpotFleetRequests"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring"
  role = aws_iam_role.monitoring.name
}

locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    compose     = file("${path.module}/files/docker-compose.yml")
    prometheus  = file("${path.module}/files/prometheus.yml")
    alerts      = file("${path.module}/files/alerts.yml")
    dashboard   = file("${path.module}/files/dashboard.json")
    dashprov    = file("${path.module}/files/dashboards-provider.yml")
    datasources = templatefile("${path.module}/templates/datasources.yml.tftpl", { region = var.region })
    yace        = templatefile("${path.module}/templates/yace.yml.tftpl", { region = var.region })
  })
}

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  user_data                   = local.user_data
  user_data_replace_on_change = true

  # Hop limit 2: de containers (Grafana, YACE) moeten de instance-rol via IMDS kunnen gebruiken.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.name}-monitoring" }

  lifecycle {
    ignore_changes = [ami]
  }
}
