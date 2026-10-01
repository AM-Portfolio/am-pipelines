#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"
export ARGO_API_RETRIES="${ARGO_API_RETRIES:-20}"
for app in am-email-extractor-dev am-email-extractor-preprod; do
  echo "=== ${app} ==="
  argo_refresh_hard "$app" || true
  sleep 3
  argo_sync "$app" || true
  raw="$(argo_api GET "/api/v1/applications/${app}" || true)"
  python3 -c '
import json,sys
d=json.load(sys.stdin)
st=d.get("status") or {}
print("health", (st.get("health") or {}).get("status"),
      "sync", (st.get("sync") or {}).get("status"),
      "images", (st.get("summary") or {}).get("images"))
print("dest", (d.get("spec") or {}).get("destination"))
' <<<"$raw" || echo "parse failed"
done
