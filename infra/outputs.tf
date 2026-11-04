output "platform_vpc_id" {
  description = "ID van de Platform-VPC."
  value       = aws_vpc.platform.id
}

output "aws_region" {
  description = "Regio waarin de omgeving draait."
  value       = var.aws_region
}

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

output "sqs_queue_name" {
  description = "Naam van de SQS-queue."
  value       = aws_sqs_queue.events.name
}

output "workload_vpc_id" {
  description = "ID van de Workload-VPC."
  value       = aws_vpc.workload.id
}

output "transit_gateway_id" {
  description = "ID van de Transit Gateway."
  value       = aws_ec2_transit_gateway.this.id
}

output "workload_instance_ids" {
  description = "Instance-ID's van de bewaakte servers."
  value       = [for i in aws_instance.workload : i.id]
}

output "workload_private_ips" {
  description = "Private IP's van de bewaakte servers."
  value       = [for i in aws_instance.workload : i.private_ip]
}

output "workload_cpu_alarm_names" {
  description = "Namen van de CPU-alarmen per bewaakte server."
  value       = [for a in aws_cloudwatch_metric_alarm.workload_cpu : a.alarm_name]
}

output "observability_instance_id" {
  description = "Instance-ID van de Grafana/Loki-host."
  value       = aws_instance.observability.id
}

output "runner_instance_id" {
  description = "Instance-ID van de self-hosted runner."
  value       = aws_instance.runner.id
}

output "grafana_url" {
  description = "Grafana is alleen bereikbaar via SSM-portforwarding."
  value       = "http://localhost:3000"
}

output "soar_internal_url" {
  description = "Interne URL van de SOAR (alleen binnen de VPC)."
  value       = "http://${aws_lb.soar.dns_name}"
}

output "web_db_endpoint" {
  description = "Writer-endpoint van de database achter de website."
  value       = aws_rds_cluster.web.endpoint
}

output "website_url" {
  description = "Interne URL van de websites (via ./scripts/port-forward.sh web)."
  value       = "http://${aws_lb.soar.dns_name}:8080"
}

output "soar_alb_dns" {
  description = "DNS-naam van de interne ALB."
  value       = aws_lb.soar.dns_name
}

output "prometheus_url" {
  description = "Basis-URL van de self-hosted Prometheus op de observability-host."
  value       = "http://${local.observability_private_ip}:9090"
}

output "ecr_repository_url" {
  description = "ECR-repository voor de SOAR-image."
  value       = aws_ecr_repository.soar.repository_url
}

output "sqs_queue_url" {
  description = "SQS-queue met SOAR-events."
  value       = aws_sqs_queue.events.url
}

output "audit_bucket" {
  description = "S3-bucket met auditobjecten."
  value       = aws_s3_bucket.audit.bucket
}

output "artifacts_bucket" {
  description = "S3-bucket met Grafana-provisioning, CodeBuild-bron en rapporten."
  value       = aws_s3_bucket.artifacts.bucket
}

output "codebuild_project_name" {
  description = "CodeBuild-project dat de SOAR-image bouwt."
  value       = aws_codebuild_project.soar.name
}

output "loki_bucket" {
  description = "S3-bucket voor Loki."
  value       = aws_s3_bucket.loki.bucket
}

output "firewall_api_url" {
  description = "Basis-URL van de gesimuleerde firewall-API."
  value       = "${aws_api_gateway_stage.firewall.invoke_url}/block"
}

output "firewall_api_key_secret_arn" {
  description = "Secret met de API-key van de firewall-API."
  value       = aws_secretsmanager_secret.firewall_api.arn
}

output "db_secret_arn" {
  description = "Secret met de databasegegevens."
  value       = aws_secretsmanager_secret.db.arn
}

output "grafana_admin_secret_arn" {
  description = "Secret met het Grafana-adminwachtwoord."
  value       = aws_secretsmanager_secret.grafana.arn
}

output "handige_commando_s" {
  description = "Kant-en-klare commando's voor de demo."
  value       = <<-EOT
    Grafana openen:
      aws ssm start-session --target ${aws_instance.observability.id} \
        --document-name AWS-StartPortForwardingSession \
        --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
      open http://localhost:3000

    SOAR openen vanaf je laptop:
      aws ssm start-session --target ${aws_instance.runner.id} \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters '{"host":["${aws_lb.soar.dns_name}"],"portNumber":["80"],"localPortNumber":["8080"]}'

    Grafana-wachtwoord:
      aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.grafana.arn} \
        --query SecretString --output text

    Firewall-API-key:
      aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.firewall_api.arn} \
        --query SecretString --output text
  EOT
}
