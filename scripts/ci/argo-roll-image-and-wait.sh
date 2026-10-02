#!/usr/bin/env bash
# Roll dev/preprod image via Argo API helm parameters — NO gitops / service commits.
# Contabo Argo (ARGOCD_SERVER + ARGOCD_AUTH_TOKEN).
#
# Policy: env=dev and env=preprod always dest am-dev-apps
#   (am-apps-dev / am-apps-preprod). Contabo am-vps-nonprod is for AI agents.
# Opt-in: NONPROD_ORIGIN=vps forces Contabo Kind for that roll only.
#
# Env:
#   INPUT_SERVICE_NAME  e.g. am-api-gateway
#   INPUT_ENVIRONMENT   dev|preprod  (legacy dig accepted as alias of dev)
#   INPUT_IMAGE_TAG     GHCR tag (usually github.run_id)
#   ARGOCD_AUTH_TOKEN
# Optional:
#   ARGOCD_SERVER, WAIT_HEALTH_SECONDS
#   NONPROD_ORIGIN=vps  (opt-in Contabo Kind; default never)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=argo-api-lib.sh
source "${SCRIPT_DIR}/argo-api-lib.sh"

SVC="${INPUT_SERVICE_NAME:?}"
ENV_RAW="${INPUT_ENVIRONMENT:?}"
TAG="${INPUT_IMAGE_TAG:?}"

# Canonical env: dig → dev (compat only; never teach dig as the env name)
case "$ENV_RAW" in
  dig) ENV=dev ;;
  *) ENV="$ENV_RAW" ;;
esac
APP="${SVC}-${ENV}"

case "$ENV" in
  dev|preprod) ;;
  *)
    echo "::error::argo-roll-image-and-wait only supports dev/preprod (got env=${ENV_RAW}). Use argo-promote-and-wait for prod/dr."
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

# Ensure destination: default am-dev-apps; NONPROD_ORIGIN=vps → am-vps-nonprod (opt-in)
DEST_PATCHED="$(
  echo "$RAW" | ENV="$ENV" NONPROD_ORIGIN="${NONPROD_ORIGIN:-}" python3 -c "$(cat <<'PY'
import json, os, sys

app = json.load(sys.stdin)
env = os.environ["ENV"]
origin = (os.environ.get("NONPROD_ORIGIN") or "").strip().lower()
dest = dict((app.get("spec") or {}).get("destination") or {})
cur_name = dest.get("name") or ""
cur_ns = dest.get("namespace") or ""

want_ns = "am-apps-dev" if env == "dev" else "am-apps-preprod"
if origin == "vps":
    want_name = "am-vps-nonprod"
    reason = "NONPROD_ORIGIN=vps (opt-in Contabo Kind)"
else:
    want_name = "am-dev-apps"
    reason = "dev/preprod always am-dev-apps (VPS reserved for AI agents)"

changed = False
if cur_name != want_name or cur_ns != want_ns:
    dest["name"] = want_name
    dest["namespace"] = want_ns
    dest.pop("server", None)
    app.setdefault("spec", {})["destination"] = dest
    changed = True
    print(
        "RETARGET dest %s/%s -> %s/%s (%s)"
        % (cur_name, cur_ns, want_name, want_ns, reason),
        file=sys.stderr,
    )
else:
    print("OK dest already %s/%s (%s)" % (want_name, want_ns, reason), file=sys.stderr)

json.dump({"app": app, "changed": changed}, sys.stdout)
PY
)"
)"
CHANGED="$(echo "$DEST_PATCHED" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("changed") else "0")')"
RAW="$(echo "$DEST_PATCHED" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["app"], sys.stdout)')"
if [[ "$CHANGED" == "1" ]]; then
  echo "::notice::Retargeted ${APP} destination (${ENV}) — am-dev-apps policy (or NONPROD_ORIGIN=vps)"
fi

# Build Application PUT body + Sync body (sources with helm.parameters) so AppSet wipe
# between PUT and sync cannot drop the tag for this sync operation.
BUILT="$(
  echo "$RAW" | TAG="$TAG" SVC="$SVC" INPUT_IMAGE_REPOSITORY="${INPUT_IMAGE_REPOSITORY:-}" python3 -c "$(cat <<'PY'
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

drop = {"global.image.tag", "global.image.digest", "image.repository"}
# Strip image overrides from every source (AppSet sometimes leaves stale
# helm.parameters on values/imageValues refs; those confuse STRICT wait logs).
cleaned = []
for i, s in enumerate(sources):
    s = dict(s or {})
    if "helm" in s and isinstance(s.get("helm"), dict):
        helm_i = dict(s["helm"])
        params_i = [
            p
            for p in list(helm_i.get("parameters") or [])
            if (p.get("name") or "") not in drop
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
params.append({"name": "global.image.tag", "value": tag})
# Repo-scoped GHCR path from Contabo publish (caller Build output). No per-service map.
# Shape matches helm image.repository under global.image.registry, e.g. am-trade-management/am-oms.
repo_override = (os.environ.get("INPUT_IMAGE_REPOSITORY") or "").strip()
if repo_override:
    params.append({"name": "image.repository", "value": repo_override})
    print("OK: also set image.repository=%s" % repo_override, file=sys.stderr)
helm["parameters"] = params
src["helm"] = helm
sources[idx] = src
app["spec"]["sources"] = sources
app.pop("status", None)

sync_body = {
    "name": app["metadata"]["name"],
    "prune": False,
    "sources": sources,
}
json.dump({"app": app, "sync": sync_body}, sys.stdout)
PY
)"
)"

PATCHED="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["app"], sys.stdout)')"
SYNC_BODY="$(echo "$BUILT" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["sync"], sys.stdout)')"

# Default: skip Application PUT — large PUTs through Cloudflare often HTTP 504.
# Sync POST with sources override still sets helm global.image.tag (+ image.repository)
# for this operation. Set ARGO_ROLL_SKIP_PUT=0 to force PUT (best-effort).
if [[ "${ARGO_ROLL_SKIP_PUT:-1}" == "0" ]]; then
  if argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null; then
    echo "OK: set helm parameters global.image.tag=${TAG} on ${APP} (Application PUT)"
  else
    echo "::warning::Application PUT failed (Cloudflare 504?) — continuing with sync sources override"
  fi
else
  echo "Skipping Application PUT (avoid Cloudflare 504) — sync sources override carries tag=${TAG}"
fi

# Sync with sources override (retries for in-progress / Kind API EOF)
errf="$(mktemp)"
attempt=1
max=3
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
