# ---------------------------------------------------------------- metrics
# Prometheus draait als container op de observability-host. Amazon Managed
# Prometheus is in dit account geblokkeerd door een service control policy.

# ---------------------------------------------------------------- opslag
resource "aws_s3_bucket" "loki" {
  bucket        = "${local.name}-loki-${random_id.bucket.hex}"
  force_destroy = true
}

resource "aws_s3_bucket" "audit" {
  bucket              = "${local.name}-audit-${random_id.bucket.hex}"
  force_destroy       = true
  object_lock_enabled = var.enable_object_lock
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${random_id.bucket.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "audit-retention"
    status = "Enabled"
    filter {}

    expiration {
      days = var.audit_retention_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "loki-retention"
    status = "Enabled"
    filter {}

    expiration {
      days = ceil(var.loki_retention_hours / 24) + 7
    }
  }
}

# Optionele Object Lock-configuratie. Alleen actief als enable_object_lock = true.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  count = var.enable_object_lock ? 1 : 0

  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.audit_retention_days
    }
  }
}

# ---------------------------------------------------------------- logging
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name}/flowlogs"
  retention_in_days = 30
}

resource "aws_flow_log" "platform" {
  vpc_id                   = aws_vpc.platform.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}

resource "aws_flow_log" "workload" {
  vpc_id                   = aws_vpc.workload.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}

# ---------------------------------------------------------------- meldingen
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-soar-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------- Grafana-secret
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${local.name}/grafana"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    admin_password = random_password.grafana.result
  })
}

# ---------------------------------------------------------------- observability-host
resource "aws_instance" "observability" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.observability_instance_type
  subnet_id              = aws_subnet.platform["app-a"].id
  private_ip             = local.observability_private_ip
  vpc_security_group_ids = [aws_security_group.observability.id]
  iam_instance_profile   = aws_iam_instance_profile.observability.name

  user_data = templatefile("${path.module}/templates/observability_bootstrap.sh", {
    region         = var.aws_region
    param_prefix   = local.param_prefix
    loki_retention = var.loki_retention_hours
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-observability"
    Role = "platform"
  }

  depends_on = [
    aws_ssm_parameter.loki_bucket,
    aws_ssm_parameter.grafana_secret,
    aws_ssm_parameter.artifacts_bucket,
    aws_s3_object.grafana_datasources,
    aws_s3_object.grafana_dashboards_provider,
    aws_s3_object.grafana_dashboard_operations,
    aws_s3_object.grafana_dashboard_soar,
  ]
}

# ---------------------------------------------------------------- DNS
resource "aws_route53_zone" "internal" {
  name = "innovatech.internal"

  vpc {
    vpc_id = aws_vpc.platform.id
  }

  vpc {
    vpc_id = aws_vpc.workload.id
  }
}

resource "aws_route53_record" "grafana" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "grafana.innovatech.internal"
  type    = "A"
  ttl     = 60
  records = [local.observability_private_ip]
}

resource "aws_route53_record" "prometheus" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "prometheus.innovatech.internal"
  type    = "A"
  ttl     = 60
  records = [local.observability_private_ip]
}

resource "aws_route53_record" "loki" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "loki.innovatech.internal"
  type    = "A"
  ttl     = 60
  records = [local.observability_private_ip]
}

resource "aws_route53_record" "soar" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "soar.innovatech.internal"
  type    = "A"

  alias {
    name                   = aws_lb.soar.dns_name
    zone_id                = aws_lb.soar.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.innovatech.internal"
  type    = "CNAME"
  ttl     = 60
  records = [aws_rds_cluster.soar.endpoint]
}

resource "aws_route53_record" "runner" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "runner.innovatech.internal"
  type    = "A"
  ttl     = 60
  records = [local.runner_private_ip]
}

# ---------------------------------------------------------------- parameters
resource "aws_ssm_parameter" "loki_bucket" {
  name  = "${local.param_prefix}/config/loki_bucket"
  type  = "String"
  value = aws_s3_bucket.loki.bucket
}

resource "aws_ssm_parameter" "artifacts_bucket" {
  name  = "${local.param_prefix}/config/artifacts_bucket"
  type  = "String"
  value = aws_s3_bucket.artifacts.bucket
}

resource "aws_ssm_parameter" "grafana_secret" {
  name  = "${local.param_prefix}/config/grafana_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.grafana.arn
}

resource "aws_ssm_parameter" "log_target" {
  name  = "${local.param_prefix}/config/workload_log_target"
  type  = "String"
  value = "${local.observability_private_ip}:6514"

  depends_on = [aws_instance.observability]
}

# ---------------------------------------------------------------- Grafana-provisioning
resource "aws_s3_object" "grafana_datasources" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "grafana/provisioning/datasources/datasources.yml"
  content = templatefile("${path.module}/../grafana/provisioning/datasources/datasources.yml.tftpl", {
    prometheus_url = "http://127.0.0.1:9090"
    region         = var.aws_region
  })
  etag = md5(templatefile("${path.module}/../grafana/provisioning/datasources/datasources.yml.tftpl", {
    prometheus_url = "http://127.0.0.1:9090"
    region         = var.aws_region
  }))
}

resource "aws_s3_object" "grafana_dashboards_provider" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "grafana/provisioning/dashboards/dashboards.yml"
  source = "${path.module}/../grafana/provisioning/dashboards/dashboards.yml"
  etag   = filemd5("${path.module}/../grafana/provisioning/dashboards/dashboards.yml")
}

resource "aws_s3_object" "grafana_dashboard_operations" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "grafana/dashboards/operations.json"
  source = "${path.module}/../grafana/dashboards/operations.json"
  etag   = filemd5("${path.module}/../grafana/dashboards/operations.json")
}

resource "aws_s3_object" "grafana_dashboard_soar" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "grafana/dashboards/soar.json"
  source = "${path.module}/../grafana/dashboards/soar.json"
  etag   = filemd5("${path.module}/../grafana/dashboards/soar.json")
}

# ---------------------------------------------------------------- alarms
resource "aws_cloudwatch_metric_alarm" "workload_cpu" {
  count = length(aws_instance.workload)

  alarm_name          = "${local.name}-cpu-${count.index}"
  alarm_description   = "CPU boven 80% op een bewaakte server"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.workload[count.index].id
  }
}

resource "aws_cloudwatch_metric_alarm" "soar_5xx" {
  alarm_name          = "${local.name}-soar-5xx"
  alarm_description   = "De SOAR geeft fouten terug"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.soar.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "soar_errors" {
  alarm_name          = "${local.name}-soar-errors"
  alarm_description   = "De SOAR verwerkt events met fouten"
  namespace           = "CS2/SOAR"
  metric_name         = "ProcessingErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = "${local.name}-soar"
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name}-dlq-not-empty"
  alarm_description   = "Er staan onverwerkte berichten in de dead-letter-queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.events_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "workload_no_data" {
  count = length(aws_instance.workload)

  alarm_name          = "${local.name}-no-data-${count.index}"
  alarm_description   = "Geen metrics meer van een bewaakte server"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 100
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.workload[count.index].id
  }
}

resource "aws_cloudwatch_metric_alarm" "soar_unhealthy" {
  alarm_name          = "${local.name}-soar-unhealthy"
  alarm_description   = "Een SOAR-taak is niet gezond"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.soar.arn_suffix
    TargetGroup  = aws_lb_target_group.soar.arn_suffix
  }
}

# ---------------------------------------------------------------- budget
resource "aws_budgets_budget" "monthly" {
  count = var.alert_email == "" ? 0 : 1

  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
