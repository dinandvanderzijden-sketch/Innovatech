#!/usr/bin/env bash
# Bouwt de SOAR-image, pusht hem naar ECR en rolt een nieuwe taakdefinitie uit.
#
# Gebruik:
#   ./scripts/build_push.sh            # tag = korte git-SHA (of datum)
#   ./scripts/build_push.sh v1.2.3     # eigen tag
#   ./scripts/build_push.sh --no-deploy
set -euo pipefail

source "$(dirname "$0")/lib.sh"
require docker aws jq

DEPLOY=1
TAG=""

for arg in "$@"; do
  case "$arg" in
    --no-deploy) DEPLOY=0 ;;
    *) TAG="$arg" ;;
  esac
done

if [[ -z "$TAG" ]]; then
  if git -C "$ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    TAG="$(git -C "$ROOT" rev-parse --short HEAD)"
  else
    TAG="$(date +%Y%m%d%H%M)"
  fi
fi

REGION="$(tf_output aws_region)"
ECR_URL="$(tf_output ecr_repository_url)"
CLUSTER="$(tf_output ecs_cluster_name)"
SERVICE="$(tf_output ecs_service_name)"
FAMILY="$(tf_output ecs_task_family)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

info "Inloggen op ECR ($REGION)"
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

info "Image bouwen: ${ECR_URL}:${TAG}"
docker build --platform linux/amd64 -t "${ECR_URL}:${TAG}" "$ROOT/soar"
docker tag "${ECR_URL}:${TAG}" "${ECR_URL}:latest"

info "Image pushen"
docker push "${ECR_URL}:${TAG}"
docker push "${ECR_URL}:latest"

if [[ "$DEPLOY" -eq 0 ]]; then
  info "Klaar (niet uitgerold)."
  exit 0
fi

info "Nieuwe taakdefinitie registreren"
CURRENT="$(aws ecs describe-task-definition --region "$REGION" \
  --task-definition "$FAMILY" --query taskDefinition --output json)"

NEW_DEF="$(echo "$CURRENT" | jq --arg IMG "${ECR_URL}:${TAG}" '
  .containerDefinitions[0].image = $IMG
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy, .enableFaultInjection)
')"

TASK_DEF_ARN="$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json "$NEW_DEF" --query taskDefinition.taskDefinitionArn --output text)"

info "Service bijwerken naar ${TASK_DEF_ARN}"
aws ecs update-service --region "$REGION" \
  --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$TASK_DEF_ARN" \
  --force-new-deployment >/dev/null

info "Wachten tot de service stabiel is (max. 10 minuten)"
wait_for_service "$REGION" "$CLUSTER" "$SERVICE"

info "Klaar. Uitgerolde tag: ${TAG}"
