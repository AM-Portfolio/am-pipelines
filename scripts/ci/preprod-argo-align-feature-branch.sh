#!/usr/bin/env bash
# Align Kind Argo Application values targetRevision + feature-branch labels/annotations.
# Env: INPUT_SERVICE_NAME, INPUT_GIT_REF
# Optional: INPUT_DEPLOYED_BY (github.actor / local user — shown in Argo Labels)
set -euo pipefail

APP="${INPUT_SERVICE_NAME}-preprod"
REF="${INPUT_GIT_REF:?INPUT_GIT_REF required}"
DEPLOYED_BY="${INPUT_DEPLOYED_BY:-}"

# K8s label values: alphanumeric / - _ . ; must start and end alphanumeric; max 63
label_safe() {
  local v="${1:-none}"
  v="${v//\//_}"
  v="${v//\\/_}"
  # printf avoids newline → trailing '_' from tr -c
  v="$(printf '%s' "$v" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-63)"
  # Strip leading/trailing non-alphanumeric (K8s requirement)
  v="$(printf '%s' "$v" | sed -E 's/^[^A-Za-z0-9]+//; s/[^A-Za-z0-9]+$//')"
  [[ -n "$v" ]] || v="none"
  printf '%s\n' "$v"
}

REF_LABEL="$(label_safe "$REF")"
BY_LABEL="$(label_safe "${DEPLOYED_BY:-unknown}")"

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

# Annotations: full branch name + owner (slashes OK)
ANN_ARGS=(
  "am.asrax.in/feature-branch-enabled=true"
  "am.asrax.in/feature-branch=${REF}"
)
if [[ -n "$DEPLOYED_BY" ]]; then
  ANN_ARGS+=("am.asrax.in/deployed-by=${DEPLOYED_BY}")
fi
kubectl -n argocd annotate application "$APP" "${ANN_ARGS[@]}" --overwrite

# Labels: visible in Argo DETAILS → Labels (Target Revision stays chart main)
LABEL_ARGS=(
  "am.asrax.in/feature-branch=enabled"
  "am.asrax.in/feature-branch-ref=${REF_LABEL}"
  "am.asrax.in/deployed-by=${BY_LABEL}"
)
kubectl -n argocd label application "$APP" "${LABEL_ARGS[@]}" --overwrite

kubectl -n argocd patch application "$APP" --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/sources/${IDX}/targetRevision\",\"value\":\"${REF}\"}]"

kubectl -n argocd annotate application "$APP" "argocd.argoproj.io/refresh=hard" --overwrite
echo "OK: $APP feature-branch enabled → values revision=$REF deployed-by=${DEPLOYED_BY:-unknown}"
