#!/usr/bin/env bash
# After Force Sync (Target Revision = main): clear feature-branch mode and
# re-enable Auto-Sync + selfHeal so the app tracks main GitOps again.
#
# Env: INPUT_SERVICE_NAME (base name, e.g. am-trade-management-service)
# Optional: ARGO_NS (default argocd)
set -euo pipefail

BASE="${INPUT_SERVICE_NAME:?INPUT_SERVICE_NAME required}"
BASE="${BASE%-preprod}"
APP="${BASE}-preprod"
ARGO_NS="${ARGO_NS:-argocd}"

if ! kubectl -n "$ARGO_NS" get application "$APP" >/dev/null 2>&1; then
  echo "WARN: Application $APP missing — skip reset"
  exit 0
fi

IDX=$(kubectl -n "$ARGO_NS" get application "$APP" -o json | python3 -c '
import json,sys
app=json.load(sys.stdin)
for i,s in enumerate(app.get("spec",{}).get("sources") or []):
    if s.get("ref")=="values":
        print(i); sys.exit(0)
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

DEFAULT=$(kubectl -n "$ARGO_NS" get application "$APP" -o json | python3 -c "
import json,sys
app=json.load(sys.stdin)
idx=int('$IDX')
sources=app.get('spec',{}).get('sources') or []
url=(sources[idx].get('repoURL') or '') if idx < len(sources) else ''
print('master' if 'am-core-services' in url else 'main')
")

echo "Reset $APP → values=$DEFAULT, Auto-Sync ON, clear feature-branch Labels"

kubectl -n "$ARGO_NS" annotate application "$APP" \
  "am.asrax.in/feature-branch-enabled=false" \
  "am.asrax.in/feature-branch=" \
  "am.asrax.in/deployed-by-" \
  "am.asrax.in/ci-paused-auto-" \
  "am.asrax.in/ci-image-" \
  --overwrite >/dev/null 2>&1 || true

kubectl -n "$ARGO_NS" patch application "$APP" --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/sources/${IDX}/targetRevision\",\"value\":\"${DEFAULT}\"}]"

# Enable Auto-Sync + selfHeal
kubectl -n "$ARGO_NS" patch application "$APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}'

kubectl -n "$ARGO_NS" label application "$APP" \
  "am.asrax.in/feature-branch=disabled" \
  "am.asrax.in/feature-branch-ref=none" \
  "am.asrax.in/auto-sync=enabled" \
  "am.asrax.in/deployed-by-" \
  --overwrite >/dev/null 2>&1 || true

kubectl -n "$ARGO_NS" annotate application "$APP" "argocd.argoproj.io/refresh=hard" --overwrite
echo "OK: $APP tracking main (Auto-Sync enabled). Force Sync if workload still OutOfSync."
