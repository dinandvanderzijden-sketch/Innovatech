output "alb_dns_name" {
  value = aws_lb.web.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.web.arn_suffix
}

output "cluster_name" {
  value = aws_ecs_cluster.web.name
}

output "service_name" {
  value = aws_ecs_service.web.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.web.repository_url
}
