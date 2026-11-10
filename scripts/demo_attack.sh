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

    ssm_run "$INSTANCE_ID" "CS2 demo CPU-belasting" "$PARAMETERS" "$REGION"

    info "Wacht op het alarm (ongeveer 5-10 minuten). Volg de SOAR met:"
    echo "  ./scripts/show_audit.sh --follow"
    ;;

  event)
    ALARM_NAME="$(tf output -json workload_cpu_alarm_names | jq -r '.[0]')"
    info "Nep-CPU-alarm sturen: ${ALARM_NAME}"
    python3 "$ROOT/scripts/send_event.py" --mode alarm --region "$REGION" \
      --alarm-name "$ALARM_NAME" --description "CPU boven 80% (demo)"
    ;;

  brute|scan|malware)
    case "$MODE" in
      brute)
        TITLE="SSH brute force gedetecteerd"
        DESC="42 mislukte SSH-logins in 60 seconden"
        SEV=high
        IP=203.0.113.7
        ;;
      scan)
        TITLE="Poortscan gedetecteerd"
        DESC="Meer dan 1000 poorten gescand in 30 seconden"
        SEV=medium
        IP=203.0.113.7
        ;;
      malware)
        TITLE="Malware en command-and-control verkeer"
        DESC="Verdacht uitgaand verkeer naar een bekend C2-domein"
        SEV=critical
        IP=198.51.100.23
        ;;
    esac
    info "Bevinding sturen: ${TITLE}"
    python3 "$ROOT/scripts/send_event.py" --mode finding --region "$REGION" \
      --title "$TITLE" --description "$DESC" --severity "$SEV" --ip "$IP"
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
