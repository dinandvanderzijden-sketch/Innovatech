variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_cidr" {
  description = "CIDR van de data-spoke (voor de egress-regel naar poort 3306)"
  type        = string
}

variable "db_secret_arn" {
  type = string
}

variable "db_endpoint" {
  type = string
}

variable "container_image" {
  type = string
}

variable "container_cpu" {
  type    = number
  default = 256
}

variable "container_memory" {
  type    = number
  default = 512
}

variable "min_tasks" {
  type    = number
  default = 2
}

variable "max_tasks" {
  type    = number
  default = 10
}

variable "health_check_path" {
  description = "Startimage heeft alleen /. Onze eigen image heeft ook /healthz; pas dit daarna eventueel aan."
  type        = string
  default     = "/"
}

variable "test_access_cidrs" {
  description = "Wie mag de blue-green testlistener (poort 8080) bereiken. Leeg = niemand."
  type        = list(string)
  default     = []
}
