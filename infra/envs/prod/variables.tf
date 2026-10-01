variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  description = "Prefix voor alle resources. De workflows in .github/workflows gebruiken dezelfde waarde."
  type        = string
  default     = "innovatech-prod"
}

variable "alert_email" {
  description = "E-mailadres voor CloudWatch-alarmen (je moet de bevestigingsmail van AWS SNS accepteren)"
  type        = string
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "container_image" {
  description = "Startimage voor ECS; de app-pipeline vervangt dit daarna door je eigen image uit ECR"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable-alpine"
}

variable "runner_policy_arn" {
  description = "IAM-policy voor de runner. Admin is simpel voor een lab; verscherp dit voor je reflectie."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}
