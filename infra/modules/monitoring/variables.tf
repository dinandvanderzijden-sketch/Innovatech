variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "db_instance_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}
