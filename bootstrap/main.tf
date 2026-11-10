# ---------------------------------------------------------------- bootstrap
# Eenmalige, blijvende onderdelen:
#
#   1. De GitHub OIDC-provider en de rol die workflows aannemen.
#   2. Niets anders. De VPC's, servers en databases staan in ../infra en
#      kunnen zonder problemen worden verwijderd.
#
# Waarom apart? Als de GitHub-rol in de hoofdstack zat, zou `terraform
# destroy` hem weghalen. Daarna kan GitHub niet meer inloggen en kun je de
# omgeving niet meer met één knop opnieuw uitrollen.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name = "${var.project}-${var.environment}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # GitHub stuurt sinds 2025 immutable ID's mee in de sub-claim:
    #   repo:owner@123456/repo@789012:ref:refs/heads/main
    # Beide vormen worden geaccepteerd.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:*",
        "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*",
      ]
    }
  }
}

resource "aws_iam_role" "github" {
  name               = "${local.name}-github"
  description        = "Rol die GitHub Actions via OIDC aanneemt voor deploy en destroy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# Let op: voor een demo. Beperk dit in productie tot de services die je
# echt nodig hebt.
resource "aws_iam_role_policy_attachment" "github_admin" {
  role       = aws_iam_role.github.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
