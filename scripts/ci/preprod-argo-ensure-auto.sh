#!/usr/bin/env bash
# Ensure preprod Argo Application has Auto-Sync + selfHeal (UI-first; no permanent pause).
# Env: INPUT_SERVICE_NAME
set -euo pipefail

APP="${INPUT_SERVICE_NAME}-preprod"
ARGO_NS="${ARGO_NS:-argocd}"

if ! kubectl -n "$ARGO_NS" get application "$APP" >/dev/null 2>&1; then
  echo "WARN: Application $APP missing — skip"
  exit 0
fi

kubectl -n "$ARGO_NS" patch application "$APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}'

kubectl -n "$ARGO_NS" annotate application "$APP" \
  "am.asrax.in/ci-paused-auto-" \
  --overwrite >/dev/null 2>&1 || true

kubectl -n "$ARGO_NS" label application "$APP" \
  "am.asrax.in/auto-sync=enabled" \
  --overwrite >/dev/null 2>&1 || true

kubectl -n "$ARGO_NS" annotate application "$APP" "argocd.argoproj.io/refresh=hard" --overwrite
echo "OK: $APP Auto-Sync enabled + hard refresh"
