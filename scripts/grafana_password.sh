#!/usr/bin/env bash
# Print het wachtwoord van de Grafana-admin.
#
#   ./scripts/grafana_password.sh
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq

aws secretsmanager get-secret-value \
  --region "$(aws_region)" \
  --secret-id "$(tf_output grafana_admin_secret_arn)" \
  --query SecretString --output text | jq -r .admin_password
