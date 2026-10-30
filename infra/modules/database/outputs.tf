output "address" {
  value = aws_db_instance.this.address
}

output "instance_id" {
  value = aws_db_instance.this.identifier
}

output "secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}
