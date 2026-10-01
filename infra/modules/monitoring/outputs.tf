output "instance_id" {
  value = aws_instance.monitoring.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
