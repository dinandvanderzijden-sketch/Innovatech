variable "name" {
  type = string
}

variable "azs" {
  description = "Precies twee Availability Zones"
  type        = list(string)
}

variable "hub_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "hub_public_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "hub_mgmt_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "web_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "web_public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "web_private_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "data_vpc_cidr" {
  type    = string
  default = "10.3.0.0/16"
}

variable "data_subnet_cidrs" {
  type    = list(string)
  default = ["10.3.1.0/24", "10.3.2.0/24"]
}
