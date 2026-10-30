#!/usr/bin/env bash
# Verwijdert de volledige demo-omgeving.
#
# Let op: dit kan niet ongedaan worden gemaakt. Staat Object Lock aan
# (enable_object_lock = true), dan moet je die eerst uitzetten en de
# retentieperiode afwachten.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require terraform

warn "Je staat op het punt de volledige CS2-omgeving te verwijderen."
warn "Dit omvat de VPC's, servers, database, buckets en alle logs."
echo
read -r -p "Typ DESTROY om door te gaan: " ANSWER
if [[ "$ANSWER" != "DESTROY" ]]; then
  echo "Geannuleerd."
  exit 0
fi

info "Terraform destroy"
tf destroy -auto-approve

info "Opgeruimd."
echo "Controleer eventueel nog handmatig:"
echo "  - ECR-images die buiten Terraform om zijn gepusht"
echo "  - handmatig aangemaakte SSM-sessies"
