#!/usr/bin/env bash
# Toont de auditresultaten van de SOAR.
#
#   ./scripts/show_audit.sh           # laatste objecten in S3
#   ./scripts/show_audit.sh --latest  # inhoud van het nieuwste object
#   ./scripts/show_audit.sh --db      # laatste rijen uit Aurora (via de SOAR-API)
#   ./scripts/show_audit.sh --follow  # live SOAR-logs uit CloudWatch
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq

MODE="${1:-list}"
REGION="$(tf_output aws_region)"
BUCKET="$(tf_output audit_bucket)"
CLUSTER="$(tf_output ecs_cluster_name)"
SERVICE="$(tf_output ecs_service_name)"

case "$MODE" in
  list)
    info "Laatste auditobjecten in s3://${BUCKET}/events/"
    aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "events/" \
      --query 'reverse(sort_by(Contents, &LastModified))[:10].[Key, LastModified, Size]' \
      --output table
    ;;

  --latest|latest)
    KEY="$(aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "events/" \
      --query 'reverse(sort_by(Contents, &LastModified))[0].Key' --output text)"
    if [[ "$KEY" == "None" || -z "$KEY" ]]; then
      echo "Nog geen auditobjecten gevonden."
      exit 0
    fi
    info "Nieuwste object: ${KEY}"
    aws s3 cp --region "$REGION" "s3://${BUCKET}/${KEY}" - | jq .
    ;;

  --db|db)
    info "Laatste auditregels uit Aurora (SOAR-API op localhost:8080)"
    if ! curl -fsS "http://localhost:8080/audit/recent?limit=10" | jq .; then
      echo "Kon de SOAR-API niet bereiken. Start eerst ./scripts/port-forward.sh soar." >&2
      exit 1
    fi
    ;;

  --follow|follow)
    info "SOAR-logs volgen (Ctrl+C om te stoppen)"
    aws logs tail "/aws/ecs/${CLUSTER}" --region "$REGION" --follow --since 10m
    ;;

  *)
    echo "Kies: (leeg), --latest, --db of --follow." >&2
    exit 1
    ;;
esac
