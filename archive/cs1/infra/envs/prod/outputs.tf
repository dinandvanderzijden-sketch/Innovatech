output "alb_dns_name" {
  value = module.web.alb_dns_name
}

output "ecr_repository_url" {
  value = module.web.ecr_repository_url
}

output "rds_endpoint" {
  value = module.database.address
}

output "runner_instance_id" {
  value = module.runner.instance_id
}

output "monitoring_instance_id" {
  value = module.monitoring.instance_id
}

output "grafana_port_forward" {
  description = "Voer dit lokaal uit en open daarna http://localhost:3000"
  value       = "aws ssm start-session --target ${module.monitoring.instance_id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000"
}
