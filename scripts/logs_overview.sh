#!/usr/bin/env bash
# Toont waar de logs en de auditgegevens staan, met de actuele namen.
#
#   ./scripts/logs_overview.sh
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws jq

REGION="$(aws_region)"

info "CloudWatch-loggroepen"
aws logs describe-log-groups --region "$REGION" \
  --query 'logGroups[].[logGroupName,retentionInDays,storedBytes]' --output table

info "S3-buckets"
for name in audit loki artifacts; do
  bucket="$(tf_output "${name}_bucket" 2>/dev/null || true)"
  [[ -z "$bucket" ]] && continue
  printf '%s\n' "  ${name}: s3://${bucket}"
done

info "Audit-objecten (nieuwste 5)"
AUDIT="$(tf_output audit_bucket)"
aws s3api list-objects-v2 --region "$REGION" --bucket "$AUDIT" --prefix events/ \
  --query 'reverse(sort_by(Contents,&LastModified))[:5].[Key,LastModified,Size]' \
  --output table

info "Waar je wat bekijkt"
cat <<'EOF'
  SOAR-logs (live)        ./scripts/show_audit.sh --follow
  Audit in S3             ./scripts/show_audit.sh --latest
  Audit in de database    ./scripts/port-forward.sh soar
                          curl "http://localhost:8080/audit/recent?limit=10" | jq .
  Serverlogs (Loki)       ./scripts/port-forward.sh grafana  -> Explore -> {job="syslog"}
  Flow logs               aws logs tail /aws/vpc/cs2-dev/flowlogs --follow
  Bestanden op de host    /var/log/remote/<hostnaam>.log (observability-host)
EOF
