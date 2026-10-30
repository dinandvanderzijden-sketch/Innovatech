provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "innovatech"
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "network" {
  source = "../../modules/network"

  name = var.name
  azs  = local.azs
}

module "database" {
  source = "../../modules/database"

  name       = var.name
  vpc_id     = module.network.data_vpc_id
  subnet_ids = module.network.data_subnet_ids
  multi_az   = var.db_multi_az

  # Alleen de web-spoke (REQ-02) en het management-subnet (IT-beheer) mogen naar poort 3306
  allowed_cidrs = [module.network.web_vpc_cidr, module.network.hub_mgmt_cidr]
}

module "web" {
  source = "../../modules/web"

  name               = var.name
  region             = var.region
  vpc_id             = module.network.web_vpc_id
  public_subnet_ids  = module.network.web_public_subnet_ids
  private_subnet_ids = module.network.web_private_subnet_ids
  db_cidr            = module.network.data_vpc_cidr
  db_secret_arn      = module.database.secret_arn
  db_endpoint        = module.database.address
  container_image    = var.container_image
}

module "runner" {
  source = "../../modules/runner"

  name       = var.name
  vpc_id     = module.network.hub_vpc_id
  subnet_id  = module.network.hub_mgmt_subnet_id
  policy_arn = var.runner_policy_arn
}

module "monitoring" {
  source = "../../modules/monitoring"

  name           = var.name
  region         = var.region
  vpc_id         = module.network.hub_vpc_id
  subnet_id      = module.network.hub_mgmt_subnet_id
  alert_email    = var.alert_email
  cluster_name   = module.web.cluster_name
  service_name   = module.web.service_name
  alb_arn_suffix = module.web.alb_arn_suffix
  db_instance_id = module.database.instance_id
}
