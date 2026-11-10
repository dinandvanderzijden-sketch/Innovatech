#!/usr/bin/env bash
# Opent een SSM-portforwarding-sessie naar Grafana, de SOAR of de website.
#
#   ./scripts/port-forward.sh grafana [local-port]
#   ./scripts/port-forward.sh soar    [local-port]
#   ./scripts/port-forward.sh web     [local-port]
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws

WHAT="${1:-grafana}"
PORT="${2:-}"
REGION="$(aws_region)"

case "$WHAT" in
  grafana)
    TARGET="$(tf_output observability_instance_id)"
    PORT="${PORT:-3000}"
    LABEL="Grafana"
    DOC="AWS-StartPortForwardingSession"
    PARAMS="{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"${PORT}\"]}"
    ;;
  soar)
    TARGET="$(tf_output runner_instance_id)"
    ALB="$(tf_output soar_alb_dns)"
    PORT="${PORT:-8080}"
    LABEL="SOAR"
    DOC="AWS-StartPortForwardingSessionToRemoteHost"
    PARAMS="{\"host\":[\"${ALB}\"],\"portNumber\":[\"80\"],\"localPortNumber\":[\"${PORT}\"]}"
    ;;
  web)
    TARGET="$(tf_output runner_instance_id)"
    ALB="$(tf_output soar_alb_dns)"
    PORT="${PORT:-8081}"
    LABEL="Website"
    DOC="AWS-StartPortForwardingSessionToRemoteHost"
    PARAMS="{\"host\":[\"${ALB}\"],\"portNumber\":[\"8080\"],\"localPortNumber\":[\"${PORT}\"]}"
    ;;
  *)
    echo "Kies 'grafana', 'soar' of 'web'." >&2
    exit 1
    ;;
esac

info "${LABEL}: http://localhost:${PORT} (blijft open tot je Ctrl+C typt)"
if [[ "$WHAT" == "grafana" ]]; then
  info "Inloggen: admin / wachtwoord uit Secrets Manager (zie docs/DEMO.md)."
fi
if [[ "$WHAT" == "web" ]]; then
  info "Ververs de pagina om te zien welke server antwoordt."
fi

exec aws ssm start-session --region "$REGION" --target "$TARGET" \
  --document-name "$DOC" --parameters "$PARAMS"
