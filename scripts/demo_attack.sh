#!/usr/bin/env bash
# Start een demo-aanval of een demo-gebeurtenis.
#
#   ./scripts/demo_attack.sh event    # neppe CPU-alarmmelding (snel, 10 sec)
#   ./scripts/demo_attack.sh cpu      # echte CPU-belasting via SSM (5-10 min)
#   ./scripts/demo_attack.sh brute    # brute-force-bevinding met bron-IP
#   ./scripts/demo_attack.sh scan     # poortscan-bevinding met bron-IP
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq

MODE="${1:-event}"
REGION="$(tf_output aws_region)"

case "$MODE" in
  cpu)
    INSTANCE_ID="$(tf output -json workload_instance_ids | jq -r '.[0]')"
    ALARM_NAME="$(tf output -json workload_cpu_alarm_names | jq -r '.[0]')"

    info "CPU-belasting starten op ${INSTANCE_ID}"
    info "Het alarm ${ALARM_NAME} slaat toe na 2 x 5 minuten boven 80%."

    PARAMETERS="$(cat <<'JSON'
{
  "commands": [
    "set -e",
    "sudo dnf install -y stress-ng >/dev/null 2>&1 || true",
    "if command -v stress-ng >/dev/null 2>&1; then nohup stress-ng --cpu 0 --timeout 900s >/var/log/cs2-demo-cpu.log 2>&1 & else for i in 1 2 3 4; do nohup timeout 900 sh -c 'while :; do :; done' >/dev/null 2>&1 & done; fi"
  ]
}
JSON
)"

    COMMAND_ID="$(aws ssm send-command --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --comment "CS2 demo CPU-belasting" \
      --parameters "$PARAMETERS" \
      --query 'Command.CommandId' --output text)"

    aws ssm wait command-executed --region "$REGION" \
      --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true

    aws ssm get-command-invocation --region "$REGION" \
      --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
      --query '[Status,StandardOutputContent,StandardErrorContent]' --output text

    info "Wacht op het alarm (ongeveer 5-10 minuten). Volg de SOAR met:"
    echo "  ./scripts/show_audit.sh --follow"
    ;;

  event)
    ALARM_NAME="$(tf output -json workload_cpu_alarm_names | jq -r '.[0]')"
    info "Nep-CPU-alarm sturen: ${ALARM_NAME}"
    python3 "$ROOT/scripts/send_event.py" --mode alarm --region "$REGION" \
      --alarm-name "$ALARM_NAME" --description "CPU boven 80% (demo)"
    ;;

  brute)
    info "Brute-force-bevinding sturen met bron-IP 203.0.113.7"
    python3 "$ROOT/scripts/send_event.py" --mode finding --region "$REGION" \
      --title "SSH brute force gedetecteerd" \
      --description "42 mislukte SSH-logins in 60 seconden" \
      --severity high --ip 203.0.113.7
    ;;

  scan)
    info "Poortscan-bevinding sturen met bron-IP 203.0.113.7"
    python3 "$ROOT/scripts/send_event.py" --mode finding --region "$REGION" \
      --title "Poortscan gedetecteerd" \
      --description "Meer dan 1000 poorten gescand in 30 seconden" \
      --severity medium --ip 203.0.113.7
    ;;

  malware)
    info "Malware-bevinding sturen"
    python3 "$ROOT/scripts/send_event.py" --mode finding --region "$REGION" \
      --title "Malware en command-and-control verkeer" \
      --description "Verdacht uitgaand verkeer naar een bekend C2-domein" \
      --severity critical --ip 198.51.100.23
    ;;

  *)
    echo "Onbekende modus: $MODE" >&2
    echo "Kies: event, cpu, brute, scan of malware." >&2
    exit 1
    ;;
esac

cat <<'EOF'

Volgende stap: bekijk het resultaat.

  ./scripts/port-forward.sh soar      # SOAR-API op http://localhost:8080
  curl http://localhost:8080/stats
  ./scripts/show_audit.sh             # auditobjecten in S3
  ./scripts/show_audit.sh --db        # rijen in Aurora
EOF
