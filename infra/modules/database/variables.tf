variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Minstens twee subnets in verschillende AZ's (vereist voor Multi-AZ)"
  type        = list(string)
}

variable "allowed_cidrs" {
  description = "CIDR's die poort 3306 mogen bereiken (web-spoke + management)"
  type        = list(string)
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "skip_final_snapshot" {
  description = "true = geen snapshot bij destroy (handig in een lab). Zet op false voor echte data."
  type        = bool
  default     = true
}
