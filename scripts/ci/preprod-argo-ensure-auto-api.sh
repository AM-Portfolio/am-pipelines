#!/usr/bin/env bash
# Enable Auto-Sync + hard refresh + sync via Argo CD API (no kubeconfig).
# Env: INPUT_SERVICE_NAME, ARGOCD_AUTH_TOKEN; optional ARGOCD_SERVER
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

APP="${INPUT_SERVICE_NAME}-preprod"

RAW="$(argo_api GET "/api/v1/applications/${APP}")"
if echo "$RAW" | grep -qiE '"code":5|not found'; then
  echo "WARN: Application $APP missing — skip"
  exit 0
fi

PATCHED="$(python3 -c '
import json, sys
app = json.load(sys.stdin)
spec = app.setdefault("spec", {})
policy = dict(spec.get("syncPolicy") or {})
policy["automated"] = {"prune": False, "selfHeal": True}
spec["syncPolicy"] = policy
md = app.setdefault("metadata", {})
labels = dict(md.get("labels") or {})
labels["am.asrax.in/auto-sync"] = "enabled"
md["labels"] = labels
ann = dict(md.get("annotations") or {})
ann.pop("am.asrax.in/ci-paused-auto", None)
md["annotations"] = ann
app.pop("status", None)
json.dump(app, sys.stdout)
' <<<"$RAW")"

argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null
argo_refresh_hard "$APP"
argo_sync "$APP"
echo "OK: $APP Auto-Sync + sync via Argo API"
