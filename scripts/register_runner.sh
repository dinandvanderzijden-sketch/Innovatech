#!/usr/bin/env bash
# Registreert de self-hosted GitHub Actions runner op de runner-instance.
#
#   ./scripts/register_runner.sh <github-pat> [owner/repo]
#
# De PAT heeft alleen de scope 'repo' (of 'administration:write' voor een
# fine-grained token) nodig om een registratietoken aan te vragen.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq curl

PAT="${1:-${GITHUB_PAT:-}}"
REPO="${2:-}"

if [[ -z "$REPO" ]]; then
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
fi

if [[ -z "$PAT" || -z "$REPO" ]]; then
  echo "Gebruik: $0 <github-pat> [owner/repo]" >&2
  exit 1
fi

REGION="$(tf_output aws_region)"
INSTANCE_ID="$(tf_output runner_instance_id)"

info "Registratietoken aanvragen voor ${REPO}"
TOKEN="$(curl -fsS -X POST \
  -H "Authorization: Bearer ${PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token" | jq -r .token)"

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Kon geen registratietoken krijgen. Controleer de PAT en de repository." >&2
  exit 1
fi

info "Runner configureren op ${INSTANCE_ID}"
PARAMETERS="$(jq -n --arg repo "$REPO" --arg token "$TOKEN" '{
  commands: [
    "set -e",
    "cd /opt/actions-runner",
    "sudo -u ec2-user ./config.sh --unattended --url https://github.com/\($repo) --token \($token) --name cs2-dev-runner --labels cs2-runner --replace",
    "sudo ./svc.sh install ec2-user",
    "sudo ./svc.sh start",
    "sudo ./svc.sh status || true"
  ]
}')"

COMMAND_ID="$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "CS2 runner registreren" \
  --parameters "$PARAMETERS" \
  --query 'Command.CommandId' --output text)"

info "Wachten op de registratie (${COMMAND_ID})"
aws ssm wait command-executed --region "$REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text

info "Klaar. De runner heeft het label 'cs2-runner'."
echo "Controleer in GitHub: Settings -> Actions -> Runners."
