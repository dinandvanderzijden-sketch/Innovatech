# ---------------------------------------------------------------- algemeen
variable "project" {
  description = "Naam van het project, gebruikt in alle resource-namen."
  type        = string
  default     = "cs2"
}

variable "environment" {
  description = "Omgevingsnaam (dev of prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Kies dev of prod."
  }
}

variable "aws_region" {
  description = "AWS-regio. Het ontwerp gebruikt Frankfurt."
  type        = string
  default     = "eu-central-1"
}

variable "owner" {
  description = "Naam van de eigenaar, voor de tags."
  type        = string
  default     = "Dinand van der Zijden"
}

variable "extra_tags" {
  description = "Extra tags bovenop de standaardtags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- netwerk
variable "platform_vpc_cidr" {
  description = "CIDR van de Platform-VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "workload_vpc_cidr" {
  description = "CIDR van de Workload-VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# ---------------------------------------------------------------- compute
variable "workload_instance_count" {
  description = "Aantal bewaakte Linux-servers (verdeeld over twee zones)."
  type        = number
  default     = 2
}

variable "workload_instance_type" {
  description = "Instance-type van de bewaakte servers."
  type        = string
  default     = "t3.micro"
}

variable "observability_instance_type" {
  description = "Instance-type van de Grafana/Loki-host."
  type        = string
  default     = "t3.small"
}

variable "runner_instance_type" {
  description = "Instance-type van de self-hosted pipeline-runner."
  type        = string
  default     = "t3.micro"
}

# ---------------------------------------------------------------- SOAR
variable "soar_cpu" {
  description = "CPU-units voor de SOAR-taak (512 = 0,5 vCPU)."
  type        = number
  default     = 512
}

variable "soar_memory" {
  description = "Geheugen (MiB) voor de SOAR-taak."
  type        = number
  default     = 1024
}

variable "soar_desired_count" {
  description = "Aantal SOAR-taken. Het ontwerp gebruikt twee taken in twee zones."
  type        = number
  default     = 2
}

variable "soar_image_tag" {
  description = "Image-tag die uitgerold wordt. De pipeline zet hier de commit-SHA neer."
  type        = string
  default     = "latest"
}

# ---------------------------------------------------------------- database
variable "aurora_min_acu" {
  description = "Minimale Aurora Serverless v2-capaciteit. 0 betekent scale-to-zero."
  type        = number
  default     = 0
}

variable "aurora_max_acu" {
  description = "Maximale Aurora Serverless v2-capaciteit."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------- integraties
variable "alert_email" {
  description = "E-mailadres voor SNS-meldingen. Leeg laat de subscription weg."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- feature flags
variable "enable_object_lock" {
  description = "Zet S3 Object Lock aan op de auditbucket. Let op: dit blokkeert destroy."
  type        = bool
  default     = false
}

variable "loki_retention_hours" {
  description = "Bewaartermijn van logs in Loki."
  type        = number
  default     = 720
}

variable "audit_retention_days" {
  description = "Bewaartermijn van auditobjecten in S3 (het ontwerp vraagt minimaal een jaar)."
  type        = number
  default     = 365
}
