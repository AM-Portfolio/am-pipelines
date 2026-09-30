#!/usr/bin/env bash
# Contabo refresh+sync + wait Healthy/Synced (pin already in am-gitops).
# Env: INPUT_SERVICE_NAME, INPUT_ENVIRONMENT, ARGOCD_AUTH_TOKEN
# Optional: INPUT_IMAGE_TAG (warn if live images lack it), WAIT_HEALTH_SECONDS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:-}"
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod|prod|dr) ;;
  *)
    echo "::error::unsupported env=${ENV}"
    exit 1
    ;;
esac

echo "Contabo sync+wait ${APP}"
argo_sync_and_wait_healthy "$APP" "$TAG"
