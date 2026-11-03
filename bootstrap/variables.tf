variable "project" {
  description = "Naam van het project."
  type        = string
  default     = "cs2"
}

variable "environment" {
  description = "Omgeving (dev of prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Regio waarin de omgeving draait."
  type        = string
  default     = "eu-central-1"
}

variable "owner" {
  description = "Naam van de eigenaar, gebruikt in tags."
  type        = string
  default     = "Dinand van der Zijden"
}

variable "github_repo" {
  description = "GitHub-repository in de vorm owner/naam."
  type        = string
}
