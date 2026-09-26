#!/usr/bin/env bash
# Align preprod Argo Application values targetRevision via Argo CD API (no kubeconfig).
# Env: INPUT_SERVICE_NAME, INPUT_GIT_REF, ARGOCD_AUTH_TOKEN
# Optional: INPUT_DEPLOYED_BY, ARGOCD_SERVER
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

APP="${INPUT_SERVICE_NAME}-preprod"
REF="${INPUT_GIT_REF:?INPUT_GIT_REF required}"
DEPLOYED_BY="${INPUT_DEPLOYED_BY:-}"

label_safe() {
  local v="${1:-none}"
  v="${v//\//_}"
  v="${v//\\/_}"
  v="$(printf '%s' "$v" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-63)"
  v="$(printf '%s' "$v" | sed -E 's/^[^A-Za-z0-9]+//; s/[^A-Za-z0-9]+$//')"
  [[ -n "$v" ]] || v="none"
  printf '%s\n' "$v"
}

export REF
export REF_LABEL
export BY_LABEL
export DEPLOYED_BY
REF_LABEL="$(label_safe "$REF")"
BY_LABEL="$(label_safe "${DEPLOYED_BY:-unknown}")"

RAW="$(argo_api GET "/api/v1/applications/${APP}")"
if echo "$RAW" | grep -qiE '"code":5|not found'; then
  echo "WARN: Application $APP missing — skip Argo align"
  exit 0
fi

PATCHED="$(echo "$RAW" | REF="$REF" REF_LABEL="$REF_LABEL" BY_LABEL="$BY_LABEL" DEPLOYED_BY="$DEPLOYED_BY" python3 -c '
import json, os, sys
app = json.load(sys.stdin)
ref = os.environ["REF"]
ref_label = os.environ["REF_LABEL"]
by_label = os.environ["BY_LABEL"]
deployed_by = os.environ.get("DEPLOYED_BY") or ""

md = app.setdefault("metadata", {})
ann = dict(md.get("annotations") or {})
labels = dict(md.get("labels") or {})
ann["am.asrax.in/feature-branch-enabled"] = "true"
ann["am.asrax.in/feature-branch"] = ref
if deployed_by:
    ann["am.asrax.in/deployed-by"] = deployed_by
labels["am.asrax.in/feature-branch"] = "enabled"
labels["am.asrax.in/feature-branch-ref"] = ref_label
labels["am.asrax.in/deployed-by"] = by_label
md["annotations"] = ann
md["labels"] = labels

sources = list((app.get("spec") or {}).get("sources") or [])
idx = -1
for i, s in enumerate(sources):
    if s.get("ref") == "values":
        idx = i
        break
if idx < 0:
    for i, s in enumerate(sources):
        u = s.get("repoURL") or ""
        if "am-pipelines" in u or "am-gitops" in u:
            continue
        if s.get("ref") == "imageValues":
            continue
        if s.get("path") == "helm/universal-chart":
            continue
        idx = i
        break
if idx < 0:
    print("ERROR: no values source", file=sys.stderr)
    sys.exit(1)
sources[idx] = dict(sources[idx])
sources[idx]["targetRevision"] = ref
app["spec"]["sources"] = sources
app.pop("status", None)
json.dump(app, sys.stdout)
')"

argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null
argo_refresh_hard "$APP"
argo_sync "$APP"
echo "OK: $APP feature-branch valuesRev=$REF via Argo API (no kubeconfig)"
