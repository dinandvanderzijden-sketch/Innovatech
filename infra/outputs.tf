# ---------------------------------------------------------------- algemeen
output "aws_region" {
  description = "Regio waarin de omgeving draait."
  value       = var.aws_region
}

output "ecr_repository_url" {
  description = "ECR-repository voor de SOAR-image."
  value       = aws_ecr_repository.soar.repository_url
}

output "codebuild_project_name" {
  description = "CodeBuild-project dat de SOAR-image bouwt."
  value       = aws_codebuild_project.soar.name
}

# ---------------------------------------------------------------- ECS en SOAR
output "ecs_cluster_name" {
  description = "Naam van het ECS-cluster."
  value       = aws_ecs_cluster.soar.name
}

output "ecs_service_name" {
  description = "Naam van de ECS-service."
  value       = aws_ecs_service.soar.name
}

output "ecs_task_family" {
  description = "Familie van de SOAR-taakdefinitie."
  value       = aws_ecs_task_definition.soar.family
}

output "soar_alb_dns" {
  description = "DNS-naam van de interne ALB."
  value       = aws_lb.soar.dns_name
}

# ---------------------------------------------------------------- servers
output "observability_instance_id" {
  description = "Instance-ID van de Grafana/Loki/Prometheus-host."
  value       = aws_instance.observability.id
}

output "runner_instance_id" {
  description = "Instance-ID van de self-hosted runner."
  value       = aws_instance.runner.id
}

output "workload_instance_ids" {
  description = "Instance-ID's van de bewaakte webservers."
  value       = [for i in aws_instance.workload : i.id]
}

output "workload_cpu_alarm_names" {
  description = "Namen van de CPU-alarmen per webserver."
  value       = [for a in aws_cloudwatch_metric_alarm.workload_cpu : a.alarm_name]
}

# ---------------------------------------------------------------- databases
output "db_endpoint" {
  description = "Writer-endpoint van de auditdatabase."
  value       = aws_rds_cluster.soar.endpoint
}

output "db_secret_arn" {
  description = "Secret met de inloggegevens van de auditdatabase."
  value       = aws_secretsmanager_secret.db.arn
}

output "web_db_endpoint" {
  description = "Writer-endpoint van de websitedatabase."
  value       = aws_rds_cluster.web.endpoint
}

output "web_db_secret_arn" {
  description = "Secret met de inloggegevens van de websitedatabase."
  value       = aws_secretsmanager_secret.web_db.arn
}

# ---------------------------------------------------------------- opslag
output "audit_bucket" {
  description = "S3-bucket met auditobjecten."
  value       = aws_s3_bucket.audit.bucket
}

output "loki_bucket" {
  description = "S3-bucket voor Loki."
  value       = aws_s3_bucket.loki.bucket
}

output "artifacts_bucket" {
  description = "S3-bucket met provisioning, buildbron en rapporten."
  value       = aws_s3_bucket.artifacts.bucket
}

# ---------------------------------------------------------------- geheimen
output "grafana_admin_secret_arn" {
  description = "Secret met het Grafana-adminwachtwoord."
  value       = aws_secretsmanager_secret.grafana.arn
}
