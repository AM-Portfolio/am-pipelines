#!/usr/bin/env bash
# Contabo Approve / Auto sync path for dev/preprod: pin first (gitops webhook SoT), then sync.
# Avoids long Application PUT through Cloudflare (HTTP 504 on argocd.asrax.in).
#
# Env:
#   INPUT_SERVICE_NAME, INPUT_ENVIRONMENT (dev|preprod), INPUT_IMAGE_TAG
#   GH_TOKEN / GITHUB_TOKEN, ARGOCD_AUTH_TOKEN
# Optional: ARGOCD_SERVER, WAIT_PIN_SECONDS (default 300), WAIT_HEALTH_SECONDS
#           PIN_SYNC_ATTEMPTS (default 3) — short sync retries after pin lag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV_RAW="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PIN="${WAIT_PIN_SECONDS:-300}"
SYNC_ATTEMPTS="${PIN_SYNC_ATTEMPTS:-3}"

case "$ENV_RAW" in
  dig) ENV=dev ;;
  *) ENV="$ENV_RAW" ;;
esac
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod) ;;
  *)
    echo "::error::argo-pin-then-sync only supports dev/preprod (got env=${ENV_RAW})"
    exit 1
    ;;
esac

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN required to dispatch set-image-tag"
  exit 1
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

echo "Roll (pin first): set-image-tag service=${SVC} env=${ENV} tag=${TAG}"
BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! gh workflow run set-image-tag.yml -R AM-Portfolio/am-gitops \
  -f service="${SVC}" -f env="${ENV}" -f tag="${TAG}"; then
  echo "::error::set-image-tag dispatch failed"
  exit 1
fi

echo "Waiting for set-image-tag run (up to ${WAIT_PIN}s)..."
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
        gh run view "$id" -R AM-Portfolio/am-gitops --log-failed 2>/dev/null | tail -n 40 || true
        exit 1
      fi
      echo "OK: set-image-tag run ${id} pinned ${SVC} ${ENV}=${TAG}"
      PIN_OK=1
      break 2
    fi
  done < <(
    gh run list -R AM-Portfolio/am-gitops --workflow=set-image-tag.yml --limit 15 \
      --json databaseId,status,conclusion,createdAt \
      --jq '.[] | [.databaseId, .status, (.conclusion // ""), .createdAt] | @tsv' 2>/dev/null || true
  )
  sleep 8
done

if [[ -z "$PIN_OK" ]]; then
  echo "::error::Timed out waiting for set-image-tag (${WAIT_PIN}s)"
  exit 1
fi

# Give Argo a moment to see the gitops commit (webhook / poll).
sleep 5

echo "Sync second: Contabo Argo refresh+sync ${APP} (no Application PUT/roll)"
argo_select_env "$ENV"
# Short per-attempt wait; outer retries cover pin lag / webhook delay.
# Never call argo-roll / long Application PUT through Cloudflare (HTTP 504).
export WAIT_HEALTH_SECONDS="${WAIT_HEALTH_SECONDS:-180}"
export STRICT_IMAGE_TAG=1
SYNC_OK=""
for attempt in $(seq 1 "$SYNC_ATTEMPTS"); do
  echo "Sync attempt ${attempt}/${SYNC_ATTEMPTS} for ${APP} tag=${TAG}"
  if argo_sync_and_wait_healthy "$APP" "$TAG"; then
    SYNC_OK=1
    break
  fi
  if (( attempt < SYNC_ATTEMPTS )); then
    echo "::warning::${APP} sync wait failed (attempt ${attempt}/${SYNC_ATTEMPTS}) — retry short sync (no Application PUT/roll)"
    sleep 15
  fi
done

if [[ -z "$SYNC_OK" ]]; then
  echo "::error::${APP} pin-then-sync failed after ${SYNC_ATTEMPTS} sync attempts — tag=${TAG}"
  echo "::notice::If Healthy but tag lag persists, check gitops pin image.repository matches nested GHCR path."
  exit 1
fi
echo "::notice::OK ${APP} pin-then-sync tag=${TAG}"
