terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "innovatech-tfstate-dinand-4821" # zelfde naam als in infra/bootstrap
    key          = "prod/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true # native S3 locking (Terraform >= 1.10), geen DynamoDB nodig
  }
}
