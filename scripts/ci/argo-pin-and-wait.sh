#!/usr/bin/env bash
# Pin flex env (dev/preprod) via am-gitops set-image-tag, then Contabo Argo
# refresh+sync and wait until Healthy/Synced (fail otherwise).
#
# Env:
#   INPUT_SERVICE_NAME  e.g. am-api-gateway
#   INPUT_ENVIRONMENT   dev|preprod
#   INPUT_IMAGE_TAG     GHCR tag
#   ARGOCD_AUTH_TOKEN   Contabo token (required)
#   ARGOCD_SERVER       default https://argocd.asrax.in
#   GH_TOKEN            for gh workflow run / watch
# Optional:
#   WAIT_PIN_SECONDS    default 180
#   WAIT_HEALTH_SECONDS default 600
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PIN="${WAIT_PIN_SECONDS:-180}"
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod) ;;
  *)
    echo "::error::argo-pin-and-wait only supports dev/preprod (got env=${ENV}). Use argo-promote-and-wait for prod/dr."
    exit 1
    ;;
esac

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN required to dispatch/watch set-image-tag"
  exit 1
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

echo "Dispatch set-image-tag: service=${SVC} env=${ENV} tag=${TAG}"
BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run set-image-tag.yml -R AM-Portfolio/am-gitops \
  -f service="$SVC" -f env="$ENV" -f tag="$TAG"

echo "Waiting for set-image-tag run to finish (up to ${WAIT_PIN}s)..."
deadline=$((SECONDS + WAIT_PIN))
PIN_OK=""
while (( SECONDS < deadline )); do
  while IFS=$'\t' read -r id status conclusion created; do
    [[ -z "$id" ]] && continue
    if [[ "$created" < "$BEFORE" ]]; then
      continue
    fi
    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" != "success" ]]; then
        echo "::error::set-image-tag run ${id} conclusion=${conclusion}"
        gh run view "$id" -R AM-Portfolio/am-gitops --log-failed | tail -n 40 || true
        exit 1
      fi
      echo "OK: set-image-tag run ${id} succeeded"
      PIN_OK=1
      break 2
    fi
  done < <(gh run list -R AM-Portfolio/am-gitops --workflow=set-image-tag.yml --limit 8 \
    --json databaseId,status,conclusion,createdAt \
    --jq '.[] | [.databaseId, .status, (.conclusion // ""), .createdAt] | @tsv')
  sleep 5
done

if [[ -z "$PIN_OK" ]]; then
  echo "::error::Timed out waiting for set-image-tag (${WAIT_PIN}s)"
  exit 1
fi

# Give argo-sync-on-tags a moment, then force Contabo sync (authoritative)
sleep 8
argo_sync_and_wait_healthy "$APP" "$TAG"
