#!/usr/bin/env bash
# Preprod Helm gate: refuse when Argo auto+selfHeal tracks main and feature-branch is off.
# Env: INPUT_SERVICE_NAME, INPUT_GIT_REF, INPUT_FORCE_HELM (true/false)
set -euo pipefail

APP="${INPUT_SERVICE_NAME%-preprod}"
APP="${APP}-preprod"
FORCE="${INPUT_FORCE_HELM:-false}"
GIT_REF="${INPUT_GIT_REF:-}"

if ! kubectl -n argocd get application "$APP" >/dev/null 2>&1; then
  echo "WARN: Argo Application $APP not found — skipping gate (Helm may proceed)"
  exit 0
fi

AUTO=$(kubectl -n argocd get application "$APP" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
FB_ON=$(kubectl -n argocd get application "$APP" -o jsonpath='{.metadata.annotations.am\.asrax\.in/feature-branch-enabled}' 2>/dev/null || true)
FB=$(kubectl -n argocd get application "$APP" -o jsonpath='{.metadata.annotations.am\.asrax\.in/feature-branch}' 2>/dev/null || true)

echo "Argo gate: app=$APP auto=${AUTO:+set} feature_branch_enabled=$FB_ON feature_branch=$FB git_ref=$GIT_REF force=$FORCE"

# Auto disabled → manual Helm OK
if [[ -z "$AUTO" || "$AUTO" == "null" || "$AUTO" == "{}" ]]; then
  echo "OK: Auto-Sync disabled — manual Helm allowed"
  exit 0
fi

# Non-main git_ref → Helm allowed (caller should align Argo feature-branch first)
if [[ -n "$GIT_REF" && "$GIT_REF" != "main" && "$GIT_REF" != "master" ]]; then
  echo "OK: feature/hotfix git_ref=$GIT_REF — Helm allowed"
  exit 0
fi

# Feature-branch enabled → require matching git_ref when both set
if [[ "$FB_ON" == "true" ]]; then
  if [[ -n "$GIT_REF" && -n "$FB" && "$GIT_REF" != "$FB" ]]; then
    echo "ERROR: git_ref=$GIT_REF does not match Argo feature-branch annotation=$FB"
    echo "Enable matching branch in Argo or pass git_ref=$FB"
    exit 1
  fi
  echo "OK: Feature-branch enabled — Helm allowed"
  exit 0
fi

# Auto + selfHeal on main, feature-branch off → refuse unless force
if [[ "$FORCE" == "true" ]]; then
  echo "WARN: force_helm=true — Helm while Argo auto on main (selfHeal may revert values)"
  exit 0
fi

echo "ERROR: Preprod Argo Auto-Sync is ON and feature-branch is OFF."
echo "Helm would fight selfHeal. Either:"
echo "  1) Disable Auto-Sync in Argo UI, or"
echo "  2) Enable feature-branch (script/amctl --ref), or"
echo "  3) Pass force_helm=true (values may revert)"
exit 1
