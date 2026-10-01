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
#   GH_TOKEN            for gh workflow run / Contents API
# Optional:
#   WAIT_PIN_SECONDS    default 240 (dispatch + serialized pin writers)
#   WAIT_HEALTH_SECONDS default 600
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PIN="${WAIT_PIN_SECONDS:-240}"
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

pin_tag() {
  local env="$1"
  local raw
  raw=$(gh api "repos/AM-Portfolio/am-gitops/contents/${env}/image-tags/${SVC}.yaml" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
  echo "$raw" | sed -n 's/.*tag:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

CURRENT="$(pin_tag "$ENV")"
if [[ -n "$CURRENT" && "$CURRENT" == "$TAG" ]]; then
  echo "Pin already ${ENV}=${TAG} — Contabo refresh+sync+wait"
  # Bot pin pushes do not always trigger argo-sync-on-tags; Approve must sync via Argo API.
  export SKIP_REFRESH_SYNC="${SKIP_REFRESH_SYNC:-0}"
  export STRICT_IMAGE_TAG=1
  argo_sync_and_wait_healthy "$APP" "$TAG"
  exit 0
fi

echo "Dispatch set-image-tag: service=${SVC} env=${ENV} tag=${TAG}"
BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run set-image-tag.yml -R AM-Portfolio/am-gitops \
  -f service="$SVC" -f env="$ENV" -f tag="$TAG"

# SoT is the pin file on main — do not fail because a sibling env/service set-image-tag
# run completed with failure (matrix Contabo Approve races). Log matching runs only.
echo "Waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG} (up to ${WAIT_PIN}s)..."
deadline=$((SECONDS + WAIT_PIN))
while (( SECONDS < deadline )); do
  NOW="$(pin_tag "$ENV")"
  if [[ -n "$NOW" && "$NOW" == "$TAG" ]]; then
    echo "OK: pin landed ${ENV}=${TAG}"
    # Best-effort: note a successful set-image-tag after BEFORE for logs
    while IFS=$'\t' read -r id status conclusion created; do
      [[ -z "$id" ]] && continue
      if [[ "$created" < "$BEFORE" ]]; then
        continue
      fi
      if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
        echo "set-image-tag run ${id} succeeded (logged; pin file is SoT)"
        break
      fi
    done < <(gh run list -R AM-Portfolio/am-gitops --workflow=set-image-tag.yml --limit 8 \
      --json databaseId,status,conclusion,createdAt \
      --jq '.[] | [.databaseId, .status, (.conclusion // ""), .createdAt] | @tsv' 2>/dev/null || true)
    # Bot pin pushes do not always trigger argo-sync-on-tags; Approve must sync via Argo API.
    export SKIP_REFRESH_SYNC="${SKIP_REFRESH_SYNC:-0}"
    export STRICT_IMAGE_TAG=1
    sleep 5
    argo_sync_and_wait_healthy "$APP" "$TAG"
    exit 0
  fi
  echo "pin still ${NOW:-none}; waiting..."
  sleep 5
done

echo "::error::Timed out waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG} (${WAIT_PIN}s)"
# Helpful diagnostics: recent set-image-tag runs
gh run list -R AM-Portfolio/am-gitops --workflow=set-image-tag.yml --limit 5 \
  --json databaseId,status,conclusion,createdAt,displayTitle \
  --jq '.[] | "\(.databaseId) \(.status) \(.conclusion // "") \(.createdAt) \(.displayTitle)"' || true
exit 1
