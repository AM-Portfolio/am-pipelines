#!/usr/bin/env bash
# Contabo Approve / Auto sync path for dev/preprod: pin first (gitops webhook SoT), then sync.
# Prefer sync-only to avoid long Application PUT through Cloudflare (HTTP 504).
# If sync cannot evidence the tag (stale helm global.image.tag / flat GHCR path),
# fall back to argo-roll-image-and-wait which sets helm params + sync with sources override.
#
# Env:
#   INPUT_SERVICE_NAME, INPUT_ENVIRONMENT (dev|preprod), INPUT_IMAGE_TAG
#   GH_TOKEN / GITHUB_TOKEN, ARGOCD_AUTH_TOKEN
# Optional: ARGOCD_SERVER, WAIT_PIN_SECONDS (default 300), WAIT_HEALTH_SECONDS
#           PIN_SYNC_ATTEMPTS (default 2) — short sync retries before roll fallback
#           INPUT_IMAGE_REPOSITORY — nested GHCR path (e.g. am-market/am-parser) for roll
#           INPUT_EXTRA_HELM_PARAMS — newline name=value helm params (forces roll path)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV_RAW="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PIN="${WAIT_PIN_SECONDS:-300}"
SYNC_ATTEMPTS="${PIN_SYNC_ATTEMPTS:-2}"

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

pin_tag() {
  local env="$1"
  local raw
  raw=$(gh api "repos/AM-Portfolio/am-gitops/contents/${env}/image-tags/${SVC}.yaml" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
  echo "$raw" | sed -n 's/.*tag:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

CURRENT="$(pin_tag "$ENV")"
if [[ -n "$CURRENT" && "$CURRENT" == "$TAG" ]]; then
  echo "Pin already ${ENV}=${TAG}"
else
  echo "Roll (pin first): set-image-tag service=${SVC} env=${ENV} tag=${TAG}"
  if ! gh workflow run set-image-tag.yml -R AM-Portfolio/am-gitops \
    -f service="${SVC}" -f env="${ENV}" -f tag="${TAG}"; then
    echo "::error::set-image-tag dispatch failed"
    exit 1
  fi

  # Pin file on am-gitops main is SoT. Do NOT watch the shared set-image-tag run
  # list for success/failure — parallel Contabo Approves (other services/envs)
  # can show cancelled siblings and falsely fail this job (news/parser bug).
  echo "Waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG} (up to ${WAIT_PIN}s)..."
  deadline=$((SECONDS + WAIT_PIN))
  PIN_OK=""
  while (( SECONDS < deadline )); do
    NOW="$(pin_tag "$ENV")"
    if [[ -n "$NOW" && "$NOW" == "$TAG" ]]; then
      echo "OK: pin landed ${ENV}=${TAG}"
      PIN_OK=1
      break
    fi
    echo "pin still ${NOW:-none}; waiting..."
    sleep 5
  done

  if [[ -z "$PIN_OK" ]]; then
    echo "::error::Timed out waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG} (${WAIT_PIN}s)"
    gh run list -R AM-Portfolio/am-gitops --workflow=set-image-tag.yml --limit 5 \
      --json databaseId,status,conclusion,createdAt \
      --jq '.[] | "\(.databaseId) \(.status) \(.conclusion // "") \(.createdAt)"' || true
    exit 1
  fi
fi

# Give Argo a moment to see the gitops commit (webhook / poll).
sleep 5

argo_select_env "$ENV"
# Shorter wait before roll fallback — stale helm params will never clear via sync-only.
export WAIT_HEALTH_SECONDS="${WAIT_HEALTH_SECONDS:-90}"
export STRICT_IMAGE_TAG=1

# Extra helm params (e.g. Google / GrowthBook clients) require the roll path.
if [[ -z "${INPUT_EXTRA_HELM_PARAMS:-}" ]]; then
  echo "Sync second: Contabo Argo refresh+sync ${APP} (prefer no Application PUT/roll)"
  SYNC_OK=""
  for attempt in $(seq 1 "$SYNC_ATTEMPTS"); do
    echo "Sync attempt ${attempt}/${SYNC_ATTEMPTS} for ${APP} tag=${TAG}"
    if argo_sync_and_wait_healthy "$APP" "$TAG"; then
      SYNC_OK=1
      break
    fi
    if (( attempt < SYNC_ATTEMPTS )); then
      echo "::warning::${APP} sync wait failed (attempt ${attempt}/${SYNC_ATTEMPTS}) — retry short sync"
      sleep 10
    fi
  done

  if [[ -n "$SYNC_OK" ]]; then
    echo "::notice::OK ${APP} pin-then-sync tag=${TAG}"
    exit 0
  fi
  echo "::warning::${APP} sync-only did not evidence tag=${TAG} (stale helm param / flat GHCR) — falling back to argo-roll-image-and-wait"
else
  echo "::notice::INPUT_EXTRA_HELM_PARAMS set — using argo-roll-image-and-wait for helm client inject"
fi
chmod +x "${SCRIPT_DIR}/argo-roll-image-and-wait.sh"
# Prefer caller INPUT_IMAGE_REPOSITORY; else nested path from pin file (set-image-tag writes it).
if [[ -z "${INPUT_IMAGE_REPOSITORY:-}" ]]; then
  PIN_RAW=$(gh api "repos/AM-Portfolio/am-gitops/contents/${ENV}/image-tags/${SVC}.yaml" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
  INPUT_IMAGE_REPOSITORY="$(echo "$PIN_RAW" | sed -n 's/.*repository:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -n "${INPUT_IMAGE_REPOSITORY}" ]]; then
    echo "Using image.repository from pin file: ${INPUT_IMAGE_REPOSITORY}"
  fi
fi
export INPUT_SERVICE_NAME="$SVC"
export INPUT_ENVIRONMENT="$ENV"
export INPUT_IMAGE_TAG="$TAG"
export INPUT_IMAGE_REPOSITORY="${INPUT_IMAGE_REPOSITORY:-}"
"${SCRIPT_DIR}/argo-roll-image-and-wait.sh"
echo "::notice::OK ${APP} pin-then-roll tag=${TAG}"
