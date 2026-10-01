#!/usr/bin/env bash
# Roll dev/preprod image via Argo API helm parameters — NO gitops / service commits.
# dev + preprod → Contabo Argo (ARGOCD_SERVER + ARGOCD_AUTH_TOKEN).
#
# When Contabo nonprod VPS is down (nonprod-dr active), dev and preprod rolls
# target laptop Kind am-dev-apps (not am-vps-nonprod).
#
# Env:
#   INPUT_SERVICE_NAME  e.g. am-api-gateway
#   INPUT_ENVIRONMENT   dev|preprod
#   INPUT_IMAGE_TAG     GHCR tag (usually github.run_id)
#   ARGOCD_AUTH_TOKEN
# Optional:
#   ARGOCD_SERVER, WAIT_HEALTH_SECONDS
#   NONPROD_ORIGIN=local|vps  (default: auto — dev always am-dev-apps;
#     preprod retargets when already on am-dev-apps, NONPROD_ORIGIN=local,
#     or Argo cluster am-vps-nonprod connection != Successful)
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

# Cluster connection SoT: am-vps-nonprod Unknown/Failed => nonprod-dr active
CLUSTERS_JSON="$(argo_api GET "/api/v1/clusters" 2>/dev/null || echo '{}')"
VPS_CONN="$(
  echo "$CLUSTERS_JSON" | python3 -c "$(cat <<'PY'
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
items = d.get("items") or d.get("clusters") or []
if isinstance(d, list):
    items = d
for c in items:
    name = c.get("name") or ""
    server = c.get("server") or ""
    if name == "am-vps-nonprod" or "am-vps-nonprod" in server:
        st = ((c.get("connectionState") or {}).get("status") or "")
        print(st)
        raise SystemExit(0)
print("")
PY
)"
)"
echo "nonprod cluster probe: am-vps-nonprod connection=${VPS_CONN:-unknown}"

# --- nonprod-dr failover: ensure destination is laptop Kind when VPS is down ---
# python3 -c "$(cat <<'PY'...)" keeps stdin free for the Application JSON pipe.
DEST_PATCHED="$(
  echo "$RAW" | ENV="$ENV" NONPROD_ORIGIN="${NONPROD_ORIGIN:-}" VPS_CONN="${VPS_CONN:-}" python3 -c "$(cat <<'PY'
import json, os, sys

app = json.load(sys.stdin)
env = os.environ["ENV"]
origin = (os.environ.get("NONPROD_ORIGIN") or "").strip().lower()
vps_conn = (os.environ.get("VPS_CONN") or "").strip()
dest = dict((app.get("spec") or {}).get("destination") or {})
cur_name = dest.get("name") or ""
cur_ns = dest.get("namespace") or ""

want_name = "am-dev-apps"
want_ns = "am-apps-dev" if env == "dev" else "am-apps-preprod"


def vps_unreachable():
    # Contabo Kind offline -> Argo reports Unknown/Failed (not Successful)
    if vps_conn and vps_conn != "Successful":
        return True
    st = app.get("status") or {}
    conds = st.get("conditions") or []
    for c in conds:
        msg = ((c.get("message") or "") + " " + (c.get("type") or "")).lower()
        if "am-vps-nonprod" in msg and any(
            x in msg
            for x in (
                "unreachable",
                "unavailable",
                "timeout",
                "connection refused",
                "i/o timeout",
                "eof",
            )
        ):
            return True
        if c.get("type") in ("ComparisonError", "InvalidSpecError") and "cluster" in msg:
            return True
    health = ((st.get("health") or {}).get("status") or "")
    if cur_name == "am-vps-nonprod" and health in ("Unknown", "Missing"):
        return True
    return False


force_dr = False
reason = ""
if env == "dev":
    force_dr = True
    reason = "dev always nonprod-dr (am-dev-apps)"
elif origin == "local":
    force_dr = True
    reason = "NONPROD_ORIGIN=local"
elif cur_name == "am-dev-apps":
    force_dr = True
    reason = "Application already on am-dev-apps"
elif origin != "vps" and vps_unreachable():
    force_dr = True
    reason = "am-vps-nonprod connection=%s - failover nonprod-dr" % (vps_conn or "down")
elif origin == "vps":
    force_dr = False
    reason = "NONPROD_ORIGIN=vps (keep Contabo nonprod-main)"
else:
    force_dr = False
    reason = "keep destination name=%s" % (cur_name or "empty")

changed = False
if force_dr and (cur_name != want_name or cur_ns != want_ns):
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
elif force_dr:
    print("OK dest already %s/%s (%s)" % (want_name, want_ns, reason), file=sys.stderr)
else:
    print(
        "OK dest unchanged name=%s ns=%s (%s)" % (cur_name, cur_ns, reason),
        file=sys.stderr,
    )

json.dump({"app": app, "changed": changed}, sys.stdout)
PY
)"
)"
CHANGED="$(echo "$DEST_PATCHED" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("changed") else "0")')"
RAW="$(echo "$DEST_PATCHED" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["app"], sys.stdout)')"
if [[ "$CHANGED" == "1" ]]; then
  echo "::notice::Retargeted ${APP} destination to nonprod-dr (am-dev-apps) — Contabo VPS down / failover"
fi

# Build Application PUT body + Sync body (sources with helm.parameters) so AppSet wipe
# between PUT and sync cannot drop the tag for this sync operation.
BUILT="$(
  echo "$RAW" | TAG="$TAG" python3 -c "$(cat <<'PY'
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
    p
    for p in list(helm.get("parameters") or [])
    if (p.get("name") or "") not in ("global.image.tag", "global.image.digest")
]
params.append({"name": "global.image.tag", "value": tag})
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

argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null
echo "OK: set helm parameters global.image.tag=${TAG} on ${APP} (no git commit)"

# Confirm param survived immediate AppSet reconcile (best-effort)
sleep 2
CHECK="$(argo_api GET "/api/v1/applications/${APP}" || true)"
PARAM_NOW="$(
  echo "$CHECK" | TAG="$TAG" python3 -c "$(cat <<'PY'
import json, sys, os
app = json.load(sys.stdin)
got = ""
for s in (app.get("spec") or {}).get("sources") or []:
    for p in ((s.get("helm") or {}).get("parameters") or []):
        if p.get("name") == "global.image.tag":
            got = p.get("value") or ""
print(got)
PY
)" 2>/dev/null || true
)"
if [[ "$PARAM_NOW" != "$TAG" ]]; then
  echo "::warning::helm.parameters wiped after PUT (got=${PARAM_NOW:-empty}) — sync will still pass sources override with tag=${TAG}"
  argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null || true
else
  echo "OK: helm.parameters still present global.image.tag=${PARAM_NOW}"
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
  # VPS cluster down while still pointing at am-vps-nonprod — force nonprod-dr and retry once
  if echo "$err" | grep -qiE 'am-vps-nonprod|failed to get server version|EOF|Unavailable|connection refused' \
    && [[ "${FAILOVER_RETRIED:-0}" != "1" ]] && [[ "$ENV" == "preprod" ]]; then
    echo "::warning::sync failed talking to Contabo nonprod-main — forcing NONPROD_ORIGIN=local and retry"
    export NONPROD_ORIGIN=local
    export FAILOVER_RETRIED=1
    PATCHED="$(
      echo "$PATCHED" | python3 -c "$(cat <<'PY'
import json, sys
app = json.load(sys.stdin)
app.setdefault("spec", {})["destination"] = {
    "name": "am-dev-apps",
    "namespace": "am-apps-preprod",
}
json.dump(app, sys.stdout)
PY
)"
    )"
    argo_api PUT "/api/v1/applications/${APP}" "$PATCHED" >/dev/null || true
    sleep 3
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
