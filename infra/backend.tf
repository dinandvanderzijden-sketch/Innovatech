# Gedeelde Terraform-state, zodat zowel je laptop als GitHub Actions
# dezelfde omgeving beheren. De bucket wordt niet door Terraform zelf
# beheerd (anders is er een kip-en-ei-probleem bij destroy).
#
# Eenmalig aangemaakt met scripts/bootstrap_state.sh. Bij een lab-reset
# maak je hem opnieuw aan met dat script en daarna `terraform init`.

terraform {
  backend "s3" {
    bucket       = "cs2-dev-tfstate-491799435972"
    key          = "cs2/dev/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
