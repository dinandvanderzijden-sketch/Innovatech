#!/usr/bin/env bash
# Voert SQL uit op de auditdatabase of de websitedatabase.
#
# De databases zijn privé. Daarom draait psql op de runner (binnen de VPC)
# en stuurt SSM de query daarheen. Het wachtwoord blijft in Secrets Manager.
#
#   ./scripts/db_query.sh                      # website: tabellen + laatste berichten
#   ./scripts/db_query.sh audit                # audit: tabellen + laatste events
#   ./scripts/db_query.sh web "select count(*) from berichten;"
#   ./scripts/db_query.sh web '\d berichten'
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq

TARGET="${1:-web}"
shift || true
SQL="${*:-}"

REGION="$(aws_region)"

case "$TARGET" in
  web)
    ENDPOINT="$(tf_output web_db_endpoint)"
    DBNAME="web"
    SECRET_ARN="$(tf_output web_db_secret_arn)"
    if [[ -z "$SQL" ]]; then
      SQL=$'\\dt\nselect id, naam, bericht, server, created_at from berichten order by id desc limit 10;'
    fi
    ;;
  audit|soar)
    ENDPOINT="$(tf_output db_endpoint)"
    DBNAME="soar"
    SECRET_ARN="$(tf_output db_secret_arn)"
    if [[ -z "$SQL" ]]; then
      SQL=$'\\dt\nselect id, occurred_at, severity, title, source_ip from audit_events order by id desc limit 10;'
    fi
    ;;
  *)
    echo "Kies 'web' of 'audit'." >&2
    exit 1
    ;;
esac

RUNNER="$(tf_output runner_instance_id)"
SQL_B64="$(printf '%s' "$SQL" | base64 -w0)"

REMOTE="$(cat <<EOF
set -e
if ! command -v psql >/dev/null 2>&1; then
  sudo dnf install -y postgresql15 >/dev/null 2>&1 || sudo dnf install -y postgresql16 >/dev/null 2>&1 || true
fi
command -v psql >/dev/null 2>&1 || { echo "psql kon niet worden geinstalleerd" >&2; exit 1; }

SECRET=\$(aws secretsmanager get-secret-value --region $REGION \\
  --secret-id $SECRET_ARN --query SecretString --output text)
DB_USER=\$(printf '%s' "\$SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')
DB_PASS=\$(printf '%s' "\$SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

printf '%s' "$SQL_B64" | base64 -d >/tmp/cs2-query.sql
PGPASSWORD="\$DB_PASS" psql -h $ENDPOINT -U "\$DB_USER" -d $DBNAME \\
  -v ON_ERROR_STOP=1 -f /tmp/cs2-query.sql
EOF
)"

info "Database: ${DBNAME} (${ENDPOINT})"
PARAMS="$(jq -n --arg c "$REMOTE" '{commands: [$c]}')"

CMD="$(aws ssm send-command --region "$REGION" \
  --instance-ids "$RUNNER" \
  --document-name AWS-RunShellScript \
  --comment "CS2 SQL-query (${DBNAME})" \
  --parameters "$PARAMS" \
  --query 'Command.CommandId' --output text)"

aws ssm wait command-executed --region "$REGION" --command-id "$CMD" --instance-id "$RUNNER" 2>/dev/null || true

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD" --instance-id "$RUNNER" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
