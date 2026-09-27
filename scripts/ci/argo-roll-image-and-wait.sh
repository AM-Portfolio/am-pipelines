#!/usr/bin/env bash
# Roll dev/preprod image via Contabo Argo API helm parameters — NO gitops / service commits.
# Sets global.image.tag on the Application chart source, syncs, waits Healthy with that tag.
#
# Env:
#   INPUT_SERVICE_NAME  e.g. am-api-gateway
#   INPUT_ENVIRONMENT   dev|preprod
#   INPUT_IMAGE_TAG     GHCR tag (usually github.run_id)
#   ARGOCD_AUTH_TOKEN   Contabo token (required)
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

echo "Contabo roll image (no gitops commit): app=${APP} tag=${TAG}"

RAW="$(argo_api GET "/api/v1/applications/${APP}")"
if echo "$RAW" | grep -qiE '"code":5|not found'; then
  echo "::error::Application ${APP} not found on Contabo"
  exit 1
fi

PATCHED="$(
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
params = list(helm.get("parameters") or [])
params = [
    p for p in params
    if (p.get("name") or "") not in ("global.image.tag", "global.image.digest")
]
params.append({"name": "global.image.tag", "value": tag})
params.append({"name": "global.image.digest", "value": ""})
helm["parameters"] = params
src["helm"] = helm
sources[idx] = src
app["spec"]["sources"] = sources
app.pop("status", None)
json.dump(app, sys.stdout)
'
)"

argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null
echo "OK: set helm parameters global.image.tag=${TAG} on ${APP} (no git commit)"

export STRICT_IMAGE_TAG=1
argo_sync_and_wait_healthy "$APP" "$TAG"
echo "::notice::OK ${APP} rolled to tag=${TAG} via Contabo API (no am-gitops / service commit)"
