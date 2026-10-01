# Hub-and-spoke: Hub (10.0.0.0/16) + web-spoke (10.1.0.0/16) + data-spoke (10.3.0.0/16),
# verbonden via een Transit Gateway. 10.2.0.0/16 is gereserveerd voor een extra spoke:
# kopieer het spoke-blok + attachment om uit te breiden zonder bestaand netwerk aan te passen (REQ-01).

locals {
  supernet = "10.0.0.0/8"
}

################ TRANSIT GATEWAY ################
resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.name} hub-and-spoke"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"

  tags = { Name = "${var.name}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = [aws_subnet.hub_mgmt.id]

  tags = { Name = "${var.name}-hub" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "web" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.web.id
  subnet_ids         = aws_subnet.web_private[*].id

  tags = { Name = "${var.name}-web" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "data" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.data.id
  subnet_ids         = aws_subnet.data[*].id

  tags = { Name = "${var.name}-data" }
}

# Centrale uitgaande internettoegang: spokes sturen 0.0.0.0/0 naar de Hub (NAT Gateway)
resource "aws_ec2_transit_gateway_route" "default_to_hub" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}

################ HUB ################
resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-hub" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id

  tags = { Name = "${var.name}-hub" }
}

resource "aws_subnet" "hub_public" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_public_subnet_cidr
  availability_zone = var.azs[0]

  tags = { Name = "${var.name}-hub-public" }
}

resource "aws_subnet" "hub_mgmt" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_mgmt_subnet_cidr
  availability_zone = var.azs[0]

  tags = { Name = "${var.name}-hub-mgmt" }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "hub" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.hub_public.id

  tags = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.hub]
}

resource "aws_route_table" "hub_public" {
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }

  route {
    cidr_block         = local.supernet
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags       = { Name = "${var.name}-hub-public" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table" "hub_mgmt" {
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub.id
  }

  route {
    cidr_block         = local.supernet
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags       = { Name = "${var.name}-hub-mgmt" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "hub_public" {
  subnet_id      = aws_subnet.hub_public.id
  route_table_id = aws_route_table.hub_public.id
}

resource "aws_route_table_association" "hub_mgmt" {
  subnet_id      = aws_subnet.hub_mgmt.id
  route_table_id = aws_route_table.hub_mgmt.id
}

################ SPOKE 1: WEB ################
# ALB en Fargate-taken moeten in dezelfde VPC staan, daarom heeft deze spoke ook publieke subnets.
resource "aws_vpc" "web" {
  cidr_block           = var.web_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-web" }
}

resource "aws_internet_gateway" "web" {
  vpc_id = aws_vpc.web.id

  tags = { Name = "${var.name}-web" }
}

resource "aws_subnet" "web_public" {
  count             = 2
  vpc_id            = aws_vpc.web.id
  cidr_block        = var.web_public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-web-public-${count.index + 1}" }
}

resource "aws_subnet" "web_private" {
  count             = 2
  vpc_id            = aws_vpc.web.id
  cidr_block        = var.web_private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-web-private-${count.index + 1}" }
}

resource "aws_route_table" "web_public" {
  vpc_id = aws_vpc.web.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.web.id
  }

  tags = { Name = "${var.name}-web-public" }
}

resource "aws_route_table" "web_private" {
  vpc_id = aws_vpc.web.id

  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags       = { Name = "${var.name}-web-private" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.web]
}

resource "aws_route_table_association" "web_public" {
  count          = 2
  subnet_id      = aws_subnet.web_public[count.index].id
  route_table_id = aws_route_table.web_public.id
}

resource "aws_route_table_association" "web_private" {
  count          = 2
  subnet_id      = aws_subnet.web_private[count.index].id
  route_table_id = aws_route_table.web_private.id
}

################ SPOKE 3: DATA ################
# Geen internetroute en geen IGW: alleen intern verkeer via de Transit Gateway.
resource "aws_vpc" "data" {
  cidr_block           = var.data_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-data" }
}

resource "aws_subnet" "data" {
  count             = 2
  vpc_id            = aws_vpc.data.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-data-${count.index + 1}" }
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.data.id

  route {
    cidr_block         = local.supernet
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags       = { Name = "${var.name}-data" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.data]
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# NACL (stateless) als tweede verdedigingslaag bovenop de Security Group van de database
resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.data.id
  subnet_ids = aws_subnet.data[*].id

  # binnen de data-VPC (Multi-AZ replicatie)
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.data_vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.data_vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # MariaDB vanaf de web-spoke
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.web_vpc_cidr
    from_port  = 3306
    to_port    = 3306
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.web_vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # MariaDB vanaf het management-subnet (IT-beheer)
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.hub_mgmt_subnet_cidr
    from_port  = 3306
    to_port    = 3306
  }

  egress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.hub_mgmt_subnet_cidr
    from_port  = 1024
    to_port    = 65535
  }

  tags = { Name = "${var.name}-data" }
}
