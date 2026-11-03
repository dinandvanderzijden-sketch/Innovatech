output "github_role_arn" {
  description = "Rol die GitHub Actions via OIDC mag aannemen."
  value       = aws_iam_role.github.arn
}

output "github_oidc_provider_arn" {
  description = "De OIDC-provider voor token.actions.githubusercontent.com."
  value       = aws_iam_openid_connect_provider.github.arn
}
