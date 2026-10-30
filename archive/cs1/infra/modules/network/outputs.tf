output "hub_vpc_id" {
  value = aws_vpc.hub.id
}

output "hub_mgmt_subnet_id" {
  value = aws_subnet.hub_mgmt.id
}

output "hub_mgmt_cidr" {
  value = var.hub_mgmt_subnet_cidr
}

output "web_vpc_id" {
  value = aws_vpc.web.id
}

output "web_vpc_cidr" {
  value = var.web_vpc_cidr
}

output "web_public_subnet_ids" {
  value = aws_subnet.web_public[*].id
}

output "web_private_subnet_ids" {
  value = aws_subnet.web_private[*].id
}

output "data_vpc_id" {
  value = aws_vpc.data.id
}

output "data_vpc_cidr" {
  value = var.data_vpc_cidr
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}
