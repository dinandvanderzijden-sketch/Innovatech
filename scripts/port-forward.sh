#!/usr/bin/env bash
# Opent een SSM-portforwarding-sessie naar Grafana of de SOAR.
#
#   ./scripts/port-forward.sh grafana [local-port]
#   ./scripts/port-forward.sh soar    [local-port]
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws

WHAT="${1:-grafana}"
LOCAL_PORT="${2:-}"

case "$WHAT" in
  grafana)
    TARGET="$(tf_output observability_instance_id)"
    LOCAL_PORT="${LOCAL_PORT:-3000}"
    info "Grafana: http://localhost:${LOCAL_PORT} (blijft open tot je Ctrl+C typt)"
    info "Inloggen: admin / wachtwoord uit Secrets Manager (zie docs/DEMO.md)."
    exec aws ssm start-session --region "$(aws_region)" \
      --target "$TARGET" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
    ;;

  soar)
    TARGET="$(tf_output runner_instance_id)"
    ALB="$(tf_output soar_alb_dns)"
    LOCAL_PORT="${LOCAL_PORT:-8080}"
    info "SOAR: http://localhost:${LOCAL_PORT} (blijft open tot je Ctrl+C typt)"
    exec aws ssm start-session --region "$(aws_region)" \
      --target "$TARGET" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"${ALB}\"],\"portNumber\":[\"80\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
    ;;

  *)
    echo "Kies 'grafana' of 'soar'." >&2
    exit 1
    ;;
esac
