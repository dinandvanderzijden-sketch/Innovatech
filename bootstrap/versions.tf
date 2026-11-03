terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Zelfde bucket als de hoofdstack, andere key. Deze stack wordt eenmalig
  # uitgerold en daarna nooit meer verwijderd: de GitHub-rol moet blijven
  # bestaan, anders kan een destroy-workflow daarna niet meer inloggen.
  backend "s3" {
    bucket       = "cs2-dev-tfstate-491799435972"
    key          = "cs2/bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
