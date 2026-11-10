#!/usr/bin/env bash
# Bouwt de SOAR-image in AWS CodeBuild en rolt hem uit.
# Handig als je lokaal geen Docker hebt.
#
#   ./scripts/build_codebuild.sh            # tag uit terraform.tfvars (latest)
#   ./scripts/build_codebuild.sh v1.2.3     # eigen tag
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require aws python3 jq

TAG="${1:-}"

REGION="$(tf_output aws_region)"
BUCKET="$(tf_output artifacts_bucket)"
PROJECT="$(tf_output codebuild_project_name)"
CLUSTER="$(tf_output ecs_cluster_name)"
SERVICE="$(tf_output ecs_service_name)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

info "Broncode inpakken"
python3 - "$ROOT/soar" "$WORKDIR/soar.zip" <<'PY'
import os
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
skip = {"__pycache__", ".pytest_cache", "tests", ".venv", "venv"}

with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in files:
            if name.endswith(".pyc"):
                continue
            full = os.path.join(root, name)
            archive.write(full, os.path.relpath(full, src))
PY

info "Uploaden naar s3://${BUCKET}/build/soar.zip"
aws s3 cp --region "$REGION" "$WORKDIR/soar.zip" "s3://${BUCKET}/build/soar.zip" >/dev/null

OVERRIDES=()
if [[ -n "$TAG" ]]; then
  OVERRIDES=(--environment-variables-override "name=IMAGE_TAG,value=${TAG},type=PLAINTEXT")
fi

info "CodeBuild starten (${PROJECT})"
BUILD_ID="$(aws codebuild start-build --region "$REGION" \
  --project-name "$PROJECT" "${OVERRIDES[@]}" \
  --query 'build.id' --output text)"

info "Build: ${BUILD_ID}"
for _ in $(seq 1 120); do
  read -r STATUS PHASE STREAM <<< "$(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" \
    --query 'builds[0].[buildStatus,currentPhase,logs.streamName]' --output text)" || true
  printf '  %-12s %s\n' "$STATUS" "$PHASE"
  case "$STATUS" in
    SUCCEEDED) break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      warn "Build mislukt. Laatste regels:"
      aws logs get-log-events --region "$REGION" \
        --log-group-name "/aws/codebuild/${PROJECT}" \
        --log-stream-name "$STREAM" \
        --limit 40 --query 'events[].message' --output text || true
      exit 1
      ;;
  esac
  sleep 10
done

if [[ "$STATUS" != "SUCCEEDED" ]]; then
  warn "Build is niet binnen 20 minuten geslaagd."
  exit 1
fi

info "Nieuwe deployment starten"
aws ecs update-service --region "$REGION" \
  --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment >/dev/null

info "Wachten tot de service stabiel is (max. 10 minuten)"
wait_for_service "$REGION" "$CLUSTER" "$SERVICE"

info "Klaar. SOAR draait met de nieuwe image."
aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].[runningCount,desiredCount,deployments[0].rolloutState]' --output table
