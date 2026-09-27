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
#   WAIT_HEALTH_SECONDS default 300
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PIN="${WAIT_PIN_SECONDS:-180}"
WAIT_HEALTH="${WAIT_HEALTH_SECONDS:-300}"
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod) ;;
  *)
    echo "::error::argo-pin-and-wait only supports dev/preprod (got env=${ENV}). Prod/DR need promote + human merge."
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
RUN_ID=""
PIN_OK=""
while (( SECONDS < deadline )); do
  while IFS=$'\t' read -r id status conclusion created; do
    [[ -z "$id" ]] && continue
    # Accept runs at/after BEFORE (ISO UTC string compare)
    if [[ "$created" < "$BEFORE" ]]; then
      continue
    fi
    if [[ "$status" == "completed" ]]; then
      RUN_ID="$id"
      if [[ "$conclusion" != "success" ]]; then
        echo "::error::set-image-tag run ${RUN_ID} conclusion=${conclusion}"
        gh run view "$RUN_ID" -R AM-Portfolio/am-gitops --log-failed | tail -n 40 || true
        exit 1
      fi
      echo "OK: set-image-tag run ${RUN_ID} succeeded"
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

# Give argo-sync-on-tags a moment, then force Contabo sync ourselves (authoritative)
sleep 8
echo "Contabo refresh+sync ${APP}"
argo_refresh_hard "$APP"
argo_sync "$APP"

echo "Waiting for ${APP} Healthy/Synced (up to ${WAIT_HEALTH}s)..."
health_deadline=$((SECONDS + WAIT_HEALTH))
while (( SECONDS < health_deadline )); do
  raw="$(argo_api GET "/api/v1/applications/${APP}" || true)"
  if [[ -z "$raw" ]]; then
    sleep 8
    continue
  fi
  health="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("status") or {}).get("health") or {}).get("status") or "")' <<<"$raw")"
  sync="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("status") or {}).get("sync") or {}).get("status") or "")' <<<"$raw")"
  images="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(((d.get("status") or {}).get("summary") or {}).get("images") or []))' <<<"$raw")"
  echo "status health=${health} sync=${sync} images=${images}"
  if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then
    if [[ -n "$TAG" && "$images" != *"$TAG"* && -n "$images" ]]; then
      echo "::warning::App Healthy/Synced but live images do not yet contain tag=${TAG} (${images})"
    fi
    echo "::notice::OK ${APP} Healthy/Synced"
    exit 0
  fi
  if [[ "$health" == "Degraded" || "$health" == "Missing" ]]; then
    echo "::error::${APP} health=${health} sync=${sync} — deploy failed"
    exit 1
  fi
  sleep 10
done

echo "::error::${APP} wait-healthy timeout after ${WAIT_HEALTH}s — deploy failed"
exit 1
