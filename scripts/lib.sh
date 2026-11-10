#!/usr/bin/env bash
# Gedeelde helpers voor de demo-scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

tf() {
  terraform -chdir="$ROOT/infra" "$@"
}

tf_output() {
  tf output -raw "$1"
}

require() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Fout: '$cmd' is niet gevonden. Installeer het en probeer opnieuw." >&2
      exit 1
    fi
  done
}

info() {
  printf '\n\033[1;36m%s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m%s\033[0m\n' "$*"
}

aws_region() {
  tf_output aws_region
}

# Voert een shell-commando op een instance uit via SSM en toont het resultaat.
ssm_run() {
  local instance="$1" comment="$2" params="$3" region="$4" id
  id="$(aws ssm send-command --region "$region" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "$comment" \
    --parameters "$params" --query 'Command.CommandId' --output text)"
  aws ssm wait command-executed --region "$region" \
    --command-id "$id" --instance-id "$instance" || true
  aws ssm get-command-invocation --region "$region" \
    --command-id "$id" --instance-id "$instance" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

# Wacht tot een ECS-service stabiel is; toont anders de laatste gebeurtenissen.
wait_for_service() {
  local region="$1" cluster="$2" service="$3"
  aws ecs wait services-stable --region "$region" \
    --cluster "$cluster" --services "$service" || {
    warn "Service nog niet stabiel:"
    aws ecs describe-services --region "$region" --cluster "$cluster" --services "$service" \
      --query 'services[0].events[:10].[createdAt,message]' --output table
    exit 1
  }
}
