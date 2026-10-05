#!/usr/bin/env bash
# Inject INPUT_EXTRA_HELM_PARAMS onto Contabo Application helm source + sync.
# Does not change global.image.tag (keeps live pin). Used after prod/dr promote
# for SPA config (Google / GrowthBook).
#
# Env: INPUT_SERVICE_NAME, INPUT_ENVIRONMENT, INPUT_EXTRA_HELM_PARAMS
#      ARGOCD_AUTH_TOKEN, ARGOCD_SERVER
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV_RAW="${INPUT_ENVIRONMENT:?}"
EXTRA="${INPUT_EXTRA_HELM_PARAMS:?}"

case "$ENV_RAW" in
  dig) ENV=dev ;;
  *) ENV="$ENV_RAW" ;;
esac
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod|prod|dr) ;;
  *)
    echo "::error::argo-inject-helm-params supports dig/preprod/prod/dr (got env=${ENV_RAW})"
    exit 1
    ;;
esac

if [[ -z "${EXTRA//[$'\n\t\r ']/}" ]]; then
  echo "No INPUT_EXTRA_HELM_PARAMS — skip"
  exit 0
fi

argo_select_env "$ENV"
echo "Inject helm params on ${APP} (env=${ENV})"

RAW="$(argo_api GET "/api/v1/applications/${APP}")"
if echo "$RAW" | grep -qiE '"code":5|not found'; then
  echo "::error::Application ${APP} not found on ${ARGOCD_SERVER}"
  exit 1
fi

BUILT="$(
  echo "$RAW" | INPUT_EXTRA_HELM_PARAMS="$EXTRA" python3 -c "$(cat <<'PY'
import json, os, sys

app = json.load(sys.stdin)
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
    print("ERROR: no helm/universal-chart source", file=sys.stderr)
    sys.exit(1)

extra_raw = (os.environ.get("INPUT_EXTRA_HELM_PARAMS") or "").strip()
extra_names = set()
extra_params = []
for line in extra_raw.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    name, value = line.split("=", 1)
    name = name.strip()
    value = value.strip()
    if not name:
        continue
    extra_names.add(name)
    extra_params.append({"name": name, "value": value})
    print("OK: helm %s" % name, file=sys.stderr)

if not extra_params:
    print("ERROR: no parsable EXTRA helm params", file=sys.stderr)
    sys.exit(1)

cleaned = []
for s in sources:
    s = dict(s or {})
    if "helm" in s and isinstance(s.get("helm"), dict):
        helm_i = dict(s["helm"])
        params_i = [
            p
            for p in list(helm_i.get("parameters") or [])
            if (p.get("name") or "") not in extra_names
        ]
        if params_i:
            helm_i["parameters"] = params_i
        else:
            helm_i.pop("parameters", None)
        if helm_i:
            s["helm"] = helm_i
        else:
            s.pop("helm", None)
    cleaned.append(s)
sources = cleaned

src = dict(sources[idx])
helm = dict(src.get("helm") or {})
params = list(helm.get("parameters") or [])
params.extend(extra_params)
helm["parameters"] = params
src["helm"] = helm
sources[idx] = src
app["spec"]["sources"] = sources
app.pop("status", None)

sync_body = {"name": app["metadata"]["name"], "prune": False, "sources": sources}
json.dump({"app": app, "sync": sync_body}, sys.stdout)
PY
)"
)"

PATCHED="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["app"], sys.stdout)')"
SYNC_BODY="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["sync"], sys.stdout)')"

if argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null; then
  echo "OK: Application PUT helm extras on ${APP}"
else
  echo "::warning::Application PUT failed — continuing with sync sources override"
fi

errf="$(mktemp)"
if ! argo_api POST "/api/v1/applications/${APP}/sync" "$SYNC_BODY" >/dev/null 2>"$errf"; then
  cat "$errf" >&2 || true
  rm -f "$errf"
  exit 1
fi
rm -f "$errf"
echo "OK: sync ${APP} with injected helm params"

export SKIP_REFRESH_SYNC=1
export STRICT_IMAGE_TAG=0
argo_sync_and_wait_healthy "$APP" ""
echo "::notice::OK ${APP} helm params injected"
