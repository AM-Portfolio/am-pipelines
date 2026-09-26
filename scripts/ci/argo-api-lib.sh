#!/usr/bin/env bash
# Argo CD REST helpers for GitHub Actions (no kubeconfig).
# Env: ARGOCD_AUTH_TOKEN (required), ARGOCD_SERVER (default https://argocd.asrax.in)
# Usage: source this file, then argo_api METHOD PATH [JSON_BODY]
set -euo pipefail

ARGOCD_SERVER="${ARGOCD_SERVER:-https://argocd.asrax.in}"
ARGOCD_SERVER="${ARGOCD_SERVER%/}"

argo_require_token() {
  if [[ -z "${ARGOCD_AUTH_TOKEN:-}" ]]; then
    echo "::error::ARGOCD_AUTH_TOKEN is required (Argo API only — never store kubeconfig in GitHub)."
    exit 1
  fi
}

argo_api() {
  local method="$1" path="$2" body="${3:-}"
  argo_require_token
  local url="${ARGOCD_SERVER}${path}"
  local args=(-sS -X "$method" -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" -H "Content-Type: application/json" -H "User-Agent: am-pipelines-ci")
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "$url"
}

argo_refresh_hard() {
  local app="$1"
  argo_api GET "/api/v1/applications/${app}?refresh=hard" >/dev/null
  echo "OK: hard refresh ${app}"
}

argo_sync() {
  local app="$1"
  argo_api POST "/api/v1/applications/${app}/sync" '{"prune":false}' >/dev/null
  echo "OK: sync ${app}"
}
