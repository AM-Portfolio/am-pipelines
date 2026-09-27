#!/usr/bin/env bash
# Roll dev/preprod image via Argo API helm parameters — NO gitops / service commits.
# dev + preprod → Contabo Argo (ARGOCD_SERVER + ARGOCD_AUTH_TOKEN).
#
# Env:
#   INPUT_SERVICE_NAME  e.g. am-api-gateway
#   INPUT_ENVIRONMENT   dev|preprod
#   INPUT_IMAGE_TAG     GHCR tag (usually github.run_id)
#   ARGOCD_AUTH_TOKEN
# Optional: ARGOCD_SERVER, WAIT_HEALTH_SECONDS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod) ;;
  *)
    echo "::error::argo-roll-image-and-wait only supports dev/preprod (got env=${ENV}). Use argo-promote-and-wait for prod/dr."
    exit 1
    ;;
esac

argo_select_env "$ENV"
echo "Argo roll image (no gitops commit): env=${ENV} server=${ARGOCD_SERVER} app=${APP} tag=${TAG}"

RAW="$(argo_api GET "/api/v1/applications/${APP}")"
if echo "$RAW" | grep -qiE '"code":5|not found'; then
  echo "::error::Application ${APP} not found on ${ARGOCD_SERVER}"
  exit 1
fi

# Build Application PUT body + Sync body (sources with helm.parameters) so AppSet wipe
# between PUT and sync cannot drop the tag for this sync operation.
BUILT="$(
  echo "$RAW" | TAG="$TAG" python3 -c '
import json, os, sys

app = json.load(sys.stdin)
tag = os.environ["TAG"]
sources = list((app.get("spec") or {}).get("sources") or [])
idx = -1
for i, s in enumerate(sources):
    if s.get("path") == "helm/universal-chart":
        idx = i
        break
if idx < 0:
    for i, s in enumerate(sources):
        if "helm" in (s or {}) and s.get("ref") not in ("values", "imageValues"):
            idx = i
            break
if idx < 0:
    print("ERROR: no helm/universal-chart source on Application", file=sys.stderr)
    sys.exit(1)

src = dict(sources[idx])
helm = dict(src.get("helm") or {})
params = [
    p for p in list(helm.get("parameters") or [])
    if (p.get("name") or "") not in ("global.image.tag", "global.image.digest")
]
params.append({"name": "global.image.tag", "value": tag})
helm["parameters"] = params
src["helm"] = helm
sources[idx] = src
app["spec"]["sources"] = sources
app.pop("status", None)

# Sync body: force this sync to use the tagged sources (multi-source apps)
sync_body = {
    "name": app["metadata"]["name"],
    "prune": False,
    "sources": sources,
}
json.dump({"app": app, "sync": sync_body}, sys.stdout)
'
)"

PATCHED="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["app"], sys.stdout)')"
SYNC_BODY="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["sync"], sys.stdout)')"

argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null
echo "OK: set helm parameters global.image.tag=${TAG} on ${APP} (no git commit)"

# Confirm param survived immediate AppSet reconcile (best-effort)
sleep 2
CHECK="$(argo_api GET "/api/v1/applications/${APP}" || true)"
PARAM_NOW="$(
  echo "$CHECK" | TAG="$TAG" python3 -c '
import json,sys,os
app=json.load(sys.stdin)
want=os.environ["TAG"]
got=""
for s in (app.get("spec") or {}).get("sources") or []:
  for p in ((s.get("helm") or {}).get("parameters") or []):
    if p.get("name")=="global.image.tag":
      got=p.get("value") or ""
print(got)
' 2>/dev/null || true
)"
if [[ "$PARAM_NOW" != "$TAG" ]]; then
  echo "::warning::helm.parameters wiped after PUT (got=${PARAM_NOW:-empty}) — sync will still pass sources override with tag=${TAG}"
  # Re-PUT once more before sync
  argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null || true
else
  echo "OK: helm.parameters still present global.image.tag=${PARAM_NOW}"
fi

# Sync with sources override (retries for in-progress)
errf="$(mktemp)"
attempt=1
max=15
while (( attempt <= max )); do
  if argo_api POST "/api/v1/applications/${APP}/sync" "$SYNC_BODY" >/dev/null 2>"$errf"; then
    echo "OK: sync ${APP} with helm global.image.tag=${TAG}"
    break
  fi
  err="$(cat "$errf" 2>/dev/null || true)"
  if echo "$err" | grep -qiE 'already in progress|"code":9'; then
    echo "::warning::sync ${APP}: another operation in progress — retry ${attempt}/${max}"
    sleep $(( 2 + attempt ))
    attempt=$((attempt + 1))
    continue
  fi
  cat "$errf" >&2 || true
  rm -f "$errf"
  exit 1
done
rm -f "$errf"
if (( attempt > max )); then
  echo "::error::sync ${APP} still blocked after ${max} retries"
  exit 1
fi

export STRICT_IMAGE_TAG=1
# Skip internal refresh+sync — we already synced with sources override
export SKIP_REFRESH_SYNC=1
argo_sync_and_wait_healthy "$APP" "$TAG"
echo "::notice::OK ${APP} rolled to tag=${TAG} via Contabo API (no am-gitops / service commit)"
