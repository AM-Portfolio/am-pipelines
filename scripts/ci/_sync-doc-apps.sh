#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/argo-api-lib.sh"
export ARGO_API_RETRIES=15
apps=(
  am-email-extractor-dev am-email-extractor-preprod
  am-document-processor-dev am-document-processor-preprod
  am-cloudinary-manager-dev am-cloudinary-manager-preprod
)
for app in "${apps[@]}"; do
  echo "=== ${app} ==="
  argo_refresh_hard "$app" || true
  sleep 1
  argo_sync "$app" || true
done
