#!/usr/bin/env bash
set -euo pipefail
source /f/am-repos/am-repos/am-pipelines/scripts/ci/argo-api-lib.sh
export ARGO_API_RETRIES=15
for app in am-email-extractor-dev am-email-extractor-preprod; do
  echo "======== $app ========"
  raw="$(argo_api GET "/api/v1/applications/${app}")"
  echo "$raw" | python3 -c '
import json,sys
d=json.load(sys.stdin)
st=d.get("status") or {}
op=st.get("operationState") or {}
conds=st.get("conditions") or []
print("health", (st.get("health") or {}).get("status"), "sync", (st.get("sync") or {}).get("status"))
print("images", (st.get("summary") or {}).get("images"))
print("op", op.get("phase"), (op.get("message") or "")[:300])
for c in conds:
  print("cond", c.get("type"), c.get("message","")[:250])
for r in st.get("resources") or []:
  if r.get("kind")=="Deployment":
    print("Deploy", r.get("name"), r.get("status"), (r.get("health") or {}).get("status"), r.get("images"))
'
done
