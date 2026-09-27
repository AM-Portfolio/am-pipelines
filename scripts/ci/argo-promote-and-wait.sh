#!/usr/bin/env bash
# Prod/DR Manual Deploy: open promote PR, wait until env pin matches TAG (human merge),
# then Contabo Argo sync+wait Healthy/Synced (fail otherwise).
#
# Env:
#   INPUT_SERVICE_NAME, INPUT_ENVIRONMENT (prod|dr), INPUT_IMAGE_TAG
#   ARGOCD_AUTH_TOKEN, GH_TOKEN
# Optional: WAIT_PROMOTE_SECONDS (default 900), WAIT_HEALTH_SECONDS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PROMOTE="${WAIT_PROMOTE_SECONDS:-900}"
APP="${SVC}-${ENV}"

case "$ENV" in
  prod|dr) ;;
  *)
    echo "::error::argo-promote-and-wait only supports prod/dr (got env=${ENV})"
    exit 1
    ;;
esac

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN required"
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
  echo "Pin already ${ENV}=${TAG} — Contabo sync+wait only"
  argo_sync_and_wait_healthy "$APP" "$TAG"
  exit 0
fi

echo "Opening promote for ${SVC} → ${ENV} (want tag=${TAG}, current=${CURRENT:-none})"
if [[ "$ENV" == "prod" ]]; then
  gh workflow run promote-to-prod.yml -R AM-Portfolio/am-gitops -f service="$SVC"
else
  gh workflow run promote-to-dr.yml -R AM-Portfolio/am-gitops -f service="$SVC"
fi

echo "::notice::Promote PR opened — human CODEOWNERS merge required within ${WAIT_PROMOTE}s"
echo "Waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG}..."
deadline=$((SECONDS + WAIT_PROMOTE))
while (( SECONDS < deadline )); do
  NOW="$(pin_tag "$ENV")"
  if [[ -n "$NOW" && "$NOW" == "$TAG" ]]; then
    echo "OK: pin landed ${ENV}=${TAG}"
    sleep 8
    argo_sync_and_wait_healthy "$APP" "$TAG"
    exit 0
  fi
  echo "pin still ${NOW:-none}; waiting..."
  sleep 20
done

echo "::error::Promote not merged (or pin not ${TAG}) within ${WAIT_PROMOTE}s — deploy failed"
echo "::error::Merge the promote PR, then re-run Manual Deploy for ${ENV}"
exit 1
