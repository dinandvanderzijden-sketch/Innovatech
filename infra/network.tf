# ---------------------------------------------------------------- VPC's
resource "aws_vpc" "platform" {
  cidr_block           = var.platform_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-platform" }
}

resource "aws_vpc" "workload" {
  cidr_block           = var.workload_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-workload" }
}

resource "aws_internet_gateway" "platform" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "${local.name}-platform-igw" }
}

resource "aws_internet_gateway" "workload" {
  vpc_id = aws_vpc.workload.id
  tags   = { Name = "${local.name}-workload-igw" }
}

# ---------------------------------------------------------------- subnetten
resource "aws_subnet" "platform" {
  for_each = local.platform_subnets

  vpc_id                  = aws_vpc.platform.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_subnet" "workload_private" {
  for_each = local.workload_private_subnets

  vpc_id                  = aws_vpc.workload.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-${each.key}"
    Tier = "workload"
  }
}

resource "aws_subnet" "workload_public" {
  for_each = local.workload_public_subnet

  vpc_id                  = aws_vpc.workload.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-${each.key}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------- NAT
resource "aws_eip" "nat_platform" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-platform" }
}

resource "aws_nat_gateway" "platform" {
  allocation_id = aws_eip.nat_platform.id
  subnet_id     = aws_subnet.platform["dmz-a"].id

  tags       = { Name = "${local.name}-nat-platform" }
  depends_on = [aws_internet_gateway.platform]
}

resource "aws_eip" "nat_workload" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-workload" }
}

resource "aws_nat_gateway" "workload" {
  allocation_id = aws_eip.nat_workload.id
  subnet_id     = aws_subnet.workload_public["workload-public"].id

  tags       = { Name = "${local.name}-nat-workload" }
  depends_on = [aws_internet_gateway.workload]
}

# ---------------------------------------------------------------- routetabellen
resource "aws_route_table" "platform_dmz" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "${local.name}-platform-dmz" }
}

resource "aws_route" "platform_dmz_internet" {
  route_table_id         = aws_route_table.platform_dmz.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.platform.id
}

resource "aws_route" "platform_dmz_tgw" {
  route_table_id         = aws_route_table.platform_dmz.id
  destination_cidr_block = var.workload_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route_table" "platform_app" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "${local.name}-platform-app" }
}

resource "aws_route" "platform_app_nat" {
  route_table_id         = aws_route_table.platform_app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.platform.id
}

resource "aws_route_table" "platform_data" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "${local.name}-platform-data" }
}

resource "aws_route" "platform_data_nat" {
  route_table_id         = aws_route_table.platform_data.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.platform.id
}

resource "aws_route_table" "workload_public" {
  vpc_id = aws_vpc.workload.id
  tags   = { Name = "${local.name}-workload-public" }
}

resource "aws_route" "workload_public_internet" {
  route_table_id         = aws_route_table.workload_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.workload.id
}

resource "aws_route_table" "workload_private" {
  vpc_id = aws_vpc.workload.id
  tags   = { Name = "${local.name}-workload-private" }
}

resource "aws_route" "workload_private_nat" {
  route_table_id         = aws_route_table.workload_private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.workload.id
}

resource "aws_route_table_association" "platform_dmz" {
  for_each = { for k, v in local.platform_subnets : k => v if v.tier == "dmz" }

  subnet_id      = aws_subnet.platform[each.key].id
  route_table_id = aws_route_table.platform_dmz.id
}

resource "aws_route_table_association" "platform_app" {
  for_each = { for k, v in local.platform_subnets : k => v if v.tier == "app" }

  subnet_id      = aws_subnet.platform[each.key].id
  route_table_id = aws_route_table.platform_app.id
}

resource "aws_route_table_association" "platform_data" {
  for_each = { for k, v in local.platform_subnets : k => v if v.tier == "data" }

  subnet_id      = aws_subnet.platform[each.key].id
  route_table_id = aws_route_table.platform_data.id
}

resource "aws_route_table_association" "workload_public" {
  for_each = local.workload_public_subnet

  subnet_id      = aws_subnet.workload_public[each.key].id
  route_table_id = aws_route_table.workload_public.id
}

resource "aws_route_table_association" "workload_private" {
  for_each = local.workload_private_subnets

  subnet_id      = aws_subnet.workload_private[each.key].id
  route_table_id = aws_route_table.workload_private.id
}

# ---------------------------------------------------------------- Transit Gateway
resource "aws_ec2_transit_gateway" "this" {
  description                     = "${local.name} hub"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "disable"

  tags = { Name = "${local.name}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "platform" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.platform.id
  subnet_ids         = [for k, v in local.platform_subnets : aws_subnet.platform[k].id if v.tier == "dmz"]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${local.name}-tgw-platform" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "workload" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.workload.id
  subnet_ids         = [for k, v in local.workload_private_subnets : aws_subnet.workload_private[k].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${local.name}-tgw-workload" }
}

resource "aws_ec2_transit_gateway_route_table" "platform" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${local.name}-tgw-rt-platform" }
}

resource "aws_ec2_transit_gateway_route_table_association" "platform" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.platform.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.platform.id
}

resource "aws_ec2_transit_gateway_route" "platform_to_workload" {
  destination_cidr_block         = var.workload_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workload.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.platform.id
}

resource "aws_ec2_transit_gateway_route_table" "workload" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${local.name}-tgw-rt-workload" }
}

resource "aws_ec2_transit_gateway_route_table_association" "workload" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workload.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.workload.id
}

resource "aws_ec2_transit_gateway_route" "workload_to_platform" {
  destination_cidr_block         = var.platform_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.platform.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.workload.id
}

resource "aws_route" "platform_app_tgw" {
  route_table_id         = aws_route_table.platform_app.id
  destination_cidr_block = var.workload_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "platform_data_tgw" {
  route_table_id         = aws_route_table.platform_data.id
  destination_cidr_block = var.workload_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "workload_private_tgw" {
  route_table_id         = aws_route_table.workload_private.id
  destination_cidr_block = var.platform_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

# ---------------------------------------------------------------- gateway endpoints
resource "aws_vpc_endpoint" "s3_platform" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.platform_app.id, aws_route_table.platform_data.id]

  tags = { Name = "${local.name}-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb_platform" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.platform_app.id, aws_route_table.platform_data.id]

  tags = { Name = "${local.name}-dynamodb-endpoint" }
}

resource "aws_vpc_endpoint" "s3_workload" {
  vpc_id            = aws_vpc.workload.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.workload_private.id]

  tags = { Name = "${local.name}-workload-s3-endpoint" }
}
