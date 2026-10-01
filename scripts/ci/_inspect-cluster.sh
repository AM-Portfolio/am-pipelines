!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/argo-api-lib.sh"
export ARGO_API_RETRIES=12
echo "=== clusters ==="
argo_api GET "/api/v1/clusters" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for c in d.get("items") or []:
  info=c.get("info") or {}
  srv=((c.get("server") or ""))
  name=((c.get("name") or ""))
  print(name, srv, "conn", (info.get("connectionState") or {}).get("status"),
        (info.get("connectionState") or {}).get("message","")[:160])
'
echo "=== am-dev-apps detail ==="
argo_api GET "/api/v1/clusters?id.type=name&id.value=am-dev-apps" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps(d, indent=2)[:2500])
' || true
