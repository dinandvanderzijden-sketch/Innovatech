data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name = "${var.project}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  param_prefix = "/${var.project}/${var.environment}"

  # De drie zones uit het ontwerp, ieder in twee Availability Zones.
  platform_subnets = {
    dmz-a  = { cidr = "10.10.0.0/24", az = local.azs[0], tier = "dmz" }
    dmz-b  = { cidr = "10.10.1.0/24", az = local.azs[1], tier = "dmz" }
    app-a  = { cidr = "10.10.16.0/24", az = local.azs[0], tier = "app" }
    app-b  = { cidr = "10.10.17.0/24", az = local.azs[1], tier = "app" }
    data-a = { cidr = "10.10.32.0/24", az = local.azs[0], tier = "data" }
    data-b = { cidr = "10.10.33.0/24", az = local.azs[1], tier = "data" }
  }

  workload_private_subnets = {
    workload-a = { cidr = "10.20.16.0/20", az = local.azs[0] }
    workload-b = { cidr = "10.20.32.0/20", az = local.azs[1] }
  }

  workload_public_subnet = {
    workload-public = { cidr = "10.20.0.0/24", az = local.azs[0] }
  }

  # Vaste adressen, zodat beheer- en loggingregels met /32 kunnen werken.
  observability_private_ip = "10.10.16.10"
  runner_private_ip        = "10.10.17.10"

  platform_app_cidrs = [for k, v in local.platform_subnets : v.cidr if v.tier == "app"]
}

resource "random_id" "bucket" {
  byte_length = 4
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "random_password" "firewall_api" {
  length  = 32
  special = false
}
