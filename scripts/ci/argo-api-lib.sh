# Argo CD REST helpers for GitHub Actions (no kubeconfig).
# dev/preprod/prod/dr → Contabo Argo (ARGOCD_SERVER / ARGOCD_AUTH_TOKEN).
# Env: ARGOCD_AUTH_TOKEN, ARGOCD_SERVER (default https://argocd.asrax.in)
# Usage: source this file, then argo_api METHOD PATH [JSON_BODY]
# Optional before calls: argo_select_env dev|preprod|prod|dr
set -euo pipefail

ARGOCD_SERVER="${ARGOCD_SERVER:-https://argocd.asrax.in}"
ARGOCD_SERVER="${ARGOCD_SERVER%/}"

argo_select_env() {
  local env="${1:-}"
  case "$env" in
    dev|preprod|prod|dr|"")
      # Contabo Argo for all envs (including dev) — never route to laptop local Argo
      ARGOCD_SERVER="${ARGOCD_SERVER:-https://argocd.asrax.in}"
      ARGOCD_SERVER="${ARGOCD_SERVER%/}"
      ;;
  esac
  export ARGOCD_SERVER ARGOCD_AUTH_TOKEN
}

argo_require_token() {
  if [[ -z "${ARGOCD_AUTH_TOKEN:-}" ]]; then
    echo "::error::ARGOCD_AUTH_TOKEN is required (Argo API only — never store kubeconfig in GitHub)."
    exit 1
  fi
  ARGOCD_SERVER="${ARGOCD_SERVER:-https://argocd.asrax.in}"
  ARGOCD_SERVER="${ARGOCD_SERVER//$'\r'/}"
  ARGOCD_SERVER="${ARGOCD_SERVER//$'\n'/}"
  ARGOCD_SERVER="${ARGOCD_SERVER%/}"
  if [[ ! "$ARGOCD_SERVER" =~ ^https://[A-Za-z0-9._-]+(/.*)?$ ]]; then
    echo "::error::ARGOCD_SERVER must be an https host URL (e.g. https://argocd.asrax.in). Got malformed value (len=${#ARGOCD_SERVER}). Re-run sync-contabo-ci-secrets.ps1."
    exit 1
  fi
  export ARGOCD_SERVER
}

argo_api() {
  local method="$1" path="$2" body="${3:-}"
  argo_require_token
  local url="${ARGOCD_SERVER}${path}"
  # Contabo sits behind Cloudflare — 502/503/504/429 are retryable (origin overload).
  local attempt=1 max="${ARGO_API_RETRIES:-8}"
  local resp http sleep_s
  while (( attempt <= max )); do
    local args=(-sS -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" -H "Content-Type: application/json" -H "User-Agent: am-pipelines-ci")
    if [[ -n "$body" ]]; then
      args+=(-d "$body")
    fi
    resp="$(curl "${args[@]}" "$url")" || true
    http="$(printf '%s' "$resp" | tail -n1)"
    resp="$(printf '%s' "$resp" | sed '$d')"
    if [[ "$http" == 2* ]]; then
      printf '%s' "$resp"
      return 0
    fi
    # Contabo sits behind Cloudflare — 502/503/504/429/520–524 are retryable (origin overload / CF edge).
    if [[ "$http" == "502" || "$http" == "503" || "$http" == "504" || "$http" == "429" || "$http" == "520" || "$http" == "521" || "$http" == "522" || "$http" == "523" || "$http" == "524" ]]; then
      # Cloudflare retry_after often ~60s on 502; backoff grows but caps at 60
      sleep_s=$(( attempt < 4 ? attempt * 5 : 60 ))
      echo "::warning::Argo API ${method} ${path} HTTP ${http} (transient) — retry ${attempt}/${max} in ${sleep_s}s" >&2
      sleep "$sleep_s"
      attempt=$((attempt + 1))
      continue
    fi
    # Contabo Argo → Kind am-vps-nonprod (:6443) sometimes EOFs briefly; Application PUT/sync returns 500.
    if [[ "$http" == "500" ]] && echo "$resp" | grep -qiE 'EOF|failed to get server version|getting k8s server version|connection reset'; then
      sleep_s=$(( attempt < 4 ? attempt * 8 : 45 ))
      echo "::warning::Argo API ${method} ${path} HTTP 500 (Kind API transient) — retry ${attempt}/${max} in ${sleep_s}s" >&2
      sleep "$sleep_s"
      attempt=$((attempt + 1))
      continue
    fi
    echo "::error::Argo API ${method} ${path} HTTP ${http}: ${resp}" >&2
    return 1
  done
  echo "::error::Argo API ${method} ${path} still failing after ${max} retries (last HTTP ${http}): ${resp}" >&2
  return 1
}

argo_refresh_hard() {
  local app="$1"
  argo_api GET "/api/v1/applications/${app}?refresh=hard" >/dev/null
  echo "OK: hard refresh ${app}"
}

argo_sync() {
  local app="$1"
  # Contabo requires ApplicationSyncRequest.name (400 without it).
  # Retry when Argo returns code 9 / "another operation is already in progress"
  # (common after Application PUT + hard refresh while auto-sync is running).
  local attempt=1 max=15 err
  local errf
  errf="$(mktemp)"
  while (( attempt <= max )); do
    if argo_api POST "/api/v1/applications/${app}/sync" "{\"name\":\"${app}\",\"prune\":false}" >/dev/null 2>"$errf"; then
      rm -f "$errf"
      echo "OK: sync ${app}"
      return 0
    fi
    err="$(cat "$errf" 2>/dev/null || true)"
    if echo "$err" | grep -qiE 'already in progress|"code":9'; then
      echo "::warning::sync ${app}: another operation in progress — retry ${attempt}/${max}"
      sleep $(( 2 + attempt ))
      attempt=$((attempt + 1))
      continue
    fi
    cat "$errf" >&2 || true
    rm -f "$errf"
    return 1
  done
  cat "$errf" >&2 || true
  rm -f "$errf"
  echo "::error::sync ${app} still blocked (another operation in progress) after ${max} retries"
  return 1
}

# Refresh+sync then poll until Healthy. Optional EXPECT_TAG substring in live images.
# Env: WAIT_HEALTH_SECONDS (default 600 — rollouts often need >5m for probes)
#      STRICT_IMAGE_TAG=1 — require expect_tag evidence before success:
#        - status.summary.images / resource images contain the tag, OR
#        - Healthy+Synced and helm param global.image.tag matches (Contabo often
#          leaves summary.images empty even when the roll applied)
# Success = health Healthy (live deploy). Synced is preferred but OutOfSync alone does not fail.
# Fail immediately on Missing; fail at timeout if not Healthy.
argo_sync_and_wait_healthy() {
  local app="$1"
  local expect_tag="${2:-}"
  local wait_health="${WAIT_HEALTH_SECONDS:-600}"
  local last_health="" last_sync="" last_images="" last_param_tag=""
  local outofsync_retried=0

  if [[ "${SKIP_REFRESH_SYNC:-0}" != "1" ]]; then
    argo_refresh_hard "$app" || true
    # Give auto-sync / refresh a moment before requesting an explicit sync
    sleep 5
    argo_sync "$app"
  else
    echo "Skipping refresh+sync (caller already synced with overrides)"
  fi

  echo "Waiting for ${app} Healthy (up to ${wait_health}s)..."
  local health_deadline=$((SECONDS + wait_health))
  while (( SECONDS < health_deadline )); do
    local raw health sync images param_tag tag_ok
    raw="$(argo_api GET "/api/v1/applications/${app}" || true)"
    if [[ -z "$raw" ]]; then
      sleep 8
      continue
    fi
    # Parse health/sync/images/helm-param in one python pass
    # images: summary.images + any status.resources[].images; param_tag: global.image.tag helm param
    read -r health sync images param_tag <<<"$(
      python3 -c '
import json, sys
d = json.load(sys.stdin)
st = d.get("status") or {}
health = ((st.get("health") or {}).get("status") or "")
sync = ((st.get("sync") or {}).get("status") or "")
imgs = list(((st.get("summary") or {}).get("images") or []))
for r in (st.get("resources") or []):
    for im in (r.get("images") or []):
        if im and im not in imgs:
            imgs.append(im)
# Contabo often leaves summary.images empty; syncResult.resources[].images has the truth
op = ((st.get("operationState") or {}).get("syncResult") or {})
for r in (op.get("resources") or []):
    for im in (r.get("images") or []):
        if im and im not in imgs:
            imgs.append(im)
for im in (op.get("images") or []):
    if im and im not in imgs:
        imgs.append(im)
param_tag = ""
for src in ((d.get("spec") or {}).get("sources") or []):
    for p in ((src.get("helm") or {}).get("parameters") or []):
        if (p.get("name") or "") == "global.image.tag":
            param_tag = p.get("value") or ""
print(health, sync, ",".join(imgs), param_tag)
' <<<"$raw"
    )"
    last_health="$health"
    last_sync="$sync"
    last_images="$images"
    last_param_tag="$param_tag"
    echo "status health=${health} sync=${sync} images=${images} helm.global.image.tag=${param_tag}"

    if [[ "$health" == "Missing" ]]; then
      echo "::error::${app} health=Missing sync=${sync} — deploy failed"
      return 1
    fi

    tag_ok=0
    if [[ -z "$expect_tag" ]]; then
      tag_ok=1
    elif [[ -n "$images" && "$images" == *"$expect_tag"* ]]; then
      tag_ok=1
    elif [[ -z "$images" && -n "$param_tag" && "$param_tag" == "$expect_tag" && "$sync" == "Synced" ]]; then
      # Contabo multi-source apps often omit summary.images; only trust helm param when images empty
      tag_ok=1
    fi
    # If images are present but show a different tag, never treat as ok
    if [[ -n "$expect_tag" && -n "$images" && "$images" != *"$expect_tag"* ]]; then
      tag_ok=0
    fi

    if [[ "$health" == "Healthy" ]]; then
      if [[ -n "$expect_tag" && "$tag_ok" != "1" ]]; then
        if [[ "${STRICT_IMAGE_TAG:-0}" == "1" ]]; then
          echo "::warning::App Healthy but tag=${expect_tag} not evidenced yet (images=${images} param=${param_tag}) — keep waiting"
          sleep 10
          continue
        fi
        if [[ -n "$images" ]]; then
          echo "::warning::App Healthy but live images do not yet contain tag=${expect_tag} (${images})"
        fi
      fi
      if [[ "$sync" == "Synced" ]]; then
        if [[ -n "$expect_tag" && "$tag_ok" == "1" && -z "$images" ]]; then
          echo "::notice::OK ${app} Healthy/Synced (tag=${expect_tag} via helm param; summary.images empty)"
        else
          echo "::notice::OK ${app} Healthy/Synced"
        fi
        return 0
      fi
      # Healthy but OutOfSync: one re-sync, then accept Healthy (do not fail CI)
      if (( outofsync_retried == 0 )); then
        echo "::warning::${app} Healthy but sync=${sync} — retrying refresh+sync once"
        outofsync_retried=1
        argo_refresh_hard "$app" || true
        argo_sync "$app" || true
        sleep 10
        continue
      fi
      if [[ "${STRICT_IMAGE_TAG:-0}" == "1" && "$tag_ok" != "1" ]]; then
        echo "::warning::${app} Healthy sync=${sync} but tag not evidenced — keep waiting"
        sleep 10
        continue
      fi
      echo "::warning::${app} Healthy but still sync=${sync} — accepting as deploy success"
      echo "::notice::OK ${app} Healthy (sync=${sync})"
      return 0
    fi

    # Progressing / Degraded / Unknown: keep polling until timeout
    sleep 10
  done
  if [[ "${STRICT_IMAGE_TAG:-0}" == "1" && -n "$expect_tag" ]]; then
    echo "::error::${app} wait-healthy timeout after ${wait_health}s — tag=${expect_tag} not evidenced (health=${last_health} sync=${last_sync} images=${last_images} param=${last_param_tag})"
  else
    echo "::error::${app} wait-healthy timeout after ${wait_health}s — last health=${last_health} sync=${last_sync} images=${last_images}"
  fi
  return 1
}
