#!/usr/bin/env bash
# Prod/DR Contabo deploy after service Environment Approve:
# direct-promote pin to am-gitops main (no CODEOWNERS PR), then Contabo sync+wait.
#
# Env:
#   INPUT_SERVICE_NAME, INPUT_ENVIRONMENT (prod|dr), INPUT_IMAGE_TAG
#   ARGOCD_AUTH_TOKEN, GH_TOKEN
# Optional: WAIT_PROMOTE_SECONDS (default 300), WAIT_HEALTH_SECONDS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
WAIT_PROMOTE="${WAIT_PROMOTE_SECONDS:-300}"
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

if [[ "$ENV" == "prod" ]]; then
  WF="promote-to-prod.yml"
else
  WF="promote-to-dr.yml"
fi

echo "Dispatch ${WF}: service=${SVC} commit_mode=direct expected_tag=${TAG}"
BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run "$WF" -R AM-Portfolio/am-gitops \
  -f service="$SVC" \
  -f commit_mode=direct \
  -f expected_tag="$TAG"

echo "Waiting for ${WF} run to finish (up to ${WAIT_PROMOTE}s)..."
deadline=$((SECONDS + WAIT_PROMOTE))
PROMOTE_OK=""
while (( SECONDS < deadline )); do
  while IFS=$'\t' read -r id status conclusion created; do
    [[ -z "$id" ]] && continue
    if [[ "$created" < "$BEFORE" ]]; then
      continue
    fi
    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" != "success" ]]; then
        echo "::error::${WF} run ${id} conclusion=${conclusion}"
        gh run view "$id" -R AM-Portfolio/am-gitops --log-failed | tail -n 40 || true
        exit 1
      fi
      echo "OK: ${WF} run ${id} succeeded"
      PROMOTE_OK=1
      break 2
    fi
  done < <(gh run list -R AM-Portfolio/am-gitops --workflow="$WF" --limit 8 \
    --json databaseId,status,conclusion,createdAt \
    --jq '.[] | [.databaseId, .status, (.conclusion // ""), .createdAt] | @tsv')
  sleep 5
done

if [[ -z "$PROMOTE_OK" ]]; then
  echo "::error::Timed out waiting for ${WF} (${WAIT_PROMOTE}s)"
  exit 1
fi

echo "Waiting for ${ENV}/image-tags/${SVC}.yaml tag=${TAG}..."
pin_deadline=$((SECONDS + 120))
while (( SECONDS < pin_deadline )); do
  NOW="$(pin_tag "$ENV")"
  if [[ -n "$NOW" && "$NOW" == "$TAG" ]]; then
    echo "OK: pin landed ${ENV}=${TAG}"
    sleep 8
    argo_sync_and_wait_healthy "$APP" "$TAG"
    exit 0
  fi
  echo "pin still ${NOW:-none}; waiting..."
  sleep 5
done

echo "::error::Promote workflow succeeded but pin not ${TAG} on main within 120s"
exit 1
