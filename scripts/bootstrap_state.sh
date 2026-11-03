#!/usr/bin/env bash
# Eenmalige bootstrap van de gedeelde state en de GitHub-rol.
#
# Gebruik dit na een lab-reset (als alle AWS-resources weg zijn) of bij de
# allereerste installatie. Daarna kun je alles vanuit GitHub doen.
#
#   ./scripts/bootstrap_state.sh              # state + GitHub-rol + infra
#   ./scripts/bootstrap_state.sh --no-infra   # alleen state + GitHub-rol
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws terraform

WITH_INFRA=1
for arg in "$@"; do
  case "$arg" in
    --no-infra) WITH_INFRA=0 ;;
    *) echo "Onbekende optie: $arg" >&2; exit 1 ;;
  esac
done

REGION="${AWS_REGION:-eu-central-1}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="cs2-dev-tfstate-${ACCOUNT}"

info "State-bucket: ${BUCKET}"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "  bestaat al"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "  aangemaakt"
fi

info "GitHub OIDC-rol (bootstrap/)"
terraform -chdir="$ROOT/bootstrap" init -input=false
terraform -chdir="$ROOT/bootstrap" apply -input=false -auto-approve

if [[ "$WITH_INFRA" -eq 1 ]]; then
  info "Hoofdstack uitrollen (infra/)"
  terraform -chdir="$ROOT/infra" init -input=false -reconfigure
  terraform -chdir="$ROOT/infra" apply -input=false -auto-approve

  info "SOAR-image bouwen en uitrollen"
  "$ROOT/scripts/build_codebuild.sh"
fi

info "Klaar"
echo "GitHub-rol: $(terraform -chdir="$ROOT/bootstrap" output -raw github_role_arn)"
echo "Zet die eventueel als repository-secret AWS_ROLE_ARN (mag ook leeg blijven)."
