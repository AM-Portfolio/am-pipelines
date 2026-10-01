#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/argo-api-lib.sh"
export ARGO_API_RETRIES=20
TAG="${1:-36907437527}"
for app in am-email-extractor-dev am-email-extractor-preprod; do
  echo "=== ${app} ==="
  argo_refresh_hard "$app" || true
  sleep 2
  argo_sync "$app" || true
done
export SKIP_REFRESH_SYNC=1
export STRICT_IMAGE_TAG=1
export WAIT_HEALTH_SECONDS=300
for app in am-email-extractor-dev am-email-extractor-preprod; do
  echo "=== wait ${app} tag=${TAG} ==="
  argo_sync_and_wait_healthy "$app" "$TAG" || true
done
