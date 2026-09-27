# Argo CD REST helpers for GitHub Actions (no kubeconfig).
# Contabo Argo (https://argocd.asrax.in) for all envs.
# Env: ARGOCD_AUTH_TOKEN (required), ARGOCD_SERVER (default https://argocd.asrax.in)
# Usage: source this file, then argo_api METHOD PATH [JSON_BODY]
set -euo pipefail

ARGOCD_SERVER="${ARGOCD_SERVER:-https://argocd.asrax.in}"
ARGOCD_SERVER="${ARGOCD_SERVER%/}"

argo_require_token() {
  if [[ -z "${ARGOCD_AUTH_TOKEN:-}" ]]; then
    echo "::error::ARGOCD_AUTH_TOKEN is required (Argo API only — never store kubeconfig in GitHub)."
    exit 1
  fi
}

argo_api() {
  local method="$1" path="$2" body="${3:-}"
  argo_require_token
  local url="${ARGOCD_SERVER}${path}"
  local args=(-sS -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" -H "Content-Type: application/json" -H "User-Agent: am-pipelines-ci")
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  local resp http
  resp="$(curl "${args[@]}" "$url")" || true
  http="$(printf '%s' "$resp" | tail -n1)"
  resp="$(printf '%s' "$resp" | sed '$d')"
  if [[ "$http" != 2* ]]; then
    echo "::error::Argo API ${method} ${path} HTTP ${http}: ${resp}" >&2
    return 1
  fi
  printf '%s' "$resp"
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
# Success = health Healthy (live deploy). Synced is preferred but OutOfSync alone does not fail.
# Fail immediately on Missing; fail at timeout if not Healthy.
argo_sync_and_wait_healthy() {
  local app="$1"
  local expect_tag="${2:-}"
  local wait_health="${WAIT_HEALTH_SECONDS:-600}"
  local last_health="" last_sync="" last_images=""
  local outofsync_retried=0

  argo_refresh_hard "$app" || true
  # Give auto-sync / refresh a moment before requesting an explicit sync
  sleep 5
  argo_sync "$app"

  echo "Waiting for ${app} Healthy (up to ${wait_health}s)..."
  local health_deadline=$((SECONDS + wait_health))
  while (( SECONDS < health_deadline )); do
    local raw health sync images
    raw="$(argo_api GET "/api/v1/applications/${app}" || true)"
    if [[ -z "$raw" ]]; then
      sleep 8
      continue
    fi
    health="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("status") or {}).get("health") or {}).get("status") or "")' <<<"$raw")"
    sync="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("status") or {}).get("sync") or {}).get("status") or "")' <<<"$raw")"
    images="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(((d.get("status") or {}).get("summary") or {}).get("images") or []))' <<<"$raw")"
    last_health="$health"
    last_sync="$sync"
    last_images="$images"
    echo "status health=${health} sync=${sync} images=${images}"

    if [[ "$health" == "Missing" ]]; then
      echo "::error::${app} health=Missing sync=${sync} — deploy failed"
      return 1
    fi

    if [[ "$health" == "Healthy" ]]; then
      if [[ -n "$expect_tag" && "$images" != *"$expect_tag"* ]]; then
        if [[ "${STRICT_IMAGE_TAG:-0}" == "1" ]]; then
          echo "::warning::App Healthy but live images missing tag=${expect_tag} (${images}) — keep waiting (STRICT_IMAGE_TAG=1)"
          sleep 10
          continue
        fi
        if [[ -n "$images" ]]; then
          echo "::warning::App Healthy but live images do not yet contain tag=${expect_tag} (${images})"
        fi
      fi
      if [[ "$sync" == "Synced" ]]; then
        echo "::notice::OK ${app} Healthy/Synced"
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
      echo "::warning::${app} Healthy but still sync=${sync} — accepting as deploy success"
      echo "::notice::OK ${app} Healthy (sync=${sync})"
      return 0
    fi

    # Progressing / Degraded / Unknown: keep polling until timeout
    sleep 10
  done
  if [[ "${STRICT_IMAGE_TAG:-0}" == "1" && -n "$expect_tag" && "$last_images" != *"$expect_tag"* ]]; then
    echo "::error::${app} wait-healthy timeout after ${wait_health}s — live images never showed tag=${expect_tag} (health=${last_health} sync=${last_sync} images=${last_images})"
  else
    echo "::error::${app} wait-healthy timeout after ${wait_health}s — last health=${last_health} sync=${last_sync} images=${last_images}"
  fi
  return 1
}
