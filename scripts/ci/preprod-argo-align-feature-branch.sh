#!/usr/bin/env bash
# Align Kind Argo Application values targetRevision + feature-branch annotations.
# Env: INPUT_SERVICE_NAME, INPUT_GIT_REF
set -euo pipefail

APP="${INPUT_SERVICE_NAME}-preprod"
REF="${INPUT_GIT_REF:?INPUT_GIT_REF required}"

if ! kubectl -n argocd get application "$APP" >/dev/null 2>&1; then
  echo "WARN: Application $APP missing — skip Argo align"
  exit 0
fi

# Find values source index (ref=values)
IDX=$(kubectl -n argocd get application "$APP" -o json | python3 -c '
import json,sys
app=json.load(sys.stdin)
for i,s in enumerate(app.get("spec",{}).get("sources") or []):
    if s.get("ref")=="values":
        print(i); sys.exit(0)
# fallback: not pipelines/gitops chart
for i,s in enumerate(app.get("spec",{}).get("sources") or []):
    u=s.get("repoURL") or ""
    if "am-pipelines" in u or "am-gitops" in u: continue
    if s.get("ref")=="imageValues": continue
    if s.get("path")=="helm/universal-chart": continue
    print(i); sys.exit(0)
print(-1)
')

if [[ "$IDX" == "-1" ]]; then
  echo "ERROR: no values source on $APP"
  exit 1
fi

kubectl -n argocd annotate application "$APP" \
  "am.asrax.in/feature-branch-enabled=true" \
  "am.asrax.in/feature-branch=${REF}" \
  --overwrite

kubectl -n argocd patch application "$APP" --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/sources/${IDX}/targetRevision\",\"value\":\"${REF}\"}]"

kubectl -n argocd annotate application "$APP" "argocd.argoproj.io/refresh=hard" --overwrite
echo "OK: $APP feature-branch enabled → values revision=$REF"
