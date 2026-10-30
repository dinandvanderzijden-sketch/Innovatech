variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "policy_arn" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}
