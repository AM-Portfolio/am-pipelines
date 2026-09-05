#!/usr/bin/env bash
# Permanent shared image roll for ALL services (no per-service logic).
#
# Order of preference:
#   1) Argo Application exists → kubectl set image (+ pause Auto-Sync so selfHeal
#      does not revert). Works for every *-dev / *-preprod / bare prod app.
#   2) Helm release secret exists → helm upgrade --reuse-values
#   3) Else → helm upgrade --install (greenfield only)
#
# Required env: RELEASE_NAME, NAMESPACE, IMAGE_REGISTRY, IMAGE_REPOSITORY, IMAGE_TAG
# Optional: CHART_DIR, LANGUAGE, PAUSE_ARGO (default true when Argo app exists),
#           ARGO_APP (default RELEASE_NAME), ARGO_NS (default argocd)
set -euo pipefail

RELEASE_NAME="${RELEASE_NAME:?}"
NAMESPACE="${NAMESPACE:?}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:?}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:?}"
IMAGE_TAG="${IMAGE_TAG:?}"
CHART_DIR="${CHART_DIR:-./am-pipelines-repo/helm/universal-chart}"
LANGUAGE="${LANGUAGE:-}"
PAUSE_ARGO="${PAUSE_ARGO:-true}"
ARGO_APP="${ARGO_APP:-$RELEASE_NAME}"
ARGO_NS="${ARGO_NS:-argocd}"

FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

HELM_EXTRA=()
if [[ "${1:-}" == "--" ]]; then
  shift
  HELM_EXTRA=("$@")
fi

argo_app_exists() {
  kubectl -n "$ARGO_NS" get application "$ARGO_APP" >/dev/null 2>&1
}

pause_argo_auto() {
  [[ "$PAUSE_ARGO" == "true" ]] || return 0
  if ! argo_app_exists; then
    return 0
  fi
  local auto
  auto=$(kubectl -n "$ARGO_NS" get application "$ARGO_APP" \
    -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
  if [[ -z "$auto" || "$auto" == "null" || "$auto" == "{}" ]]; then
    echo "Argo Auto-Sync already off on $ARGO_APP"
    return 0
  fi
  echo "Pausing Argo Auto-Sync on $ARGO_APP (CI image roll; restore Auto-Sync when done)"
  kubectl -n "$ARGO_NS" annotate application "$ARGO_APP" \
    "am.asrax.in/ci-paused-auto=true" \
    "am.asrax.in/ci-image=${FULL_IMAGE}" \
    --overwrite >/dev/null || true
  kubectl -n "$ARGO_NS" patch application "$ARGO_APP" --type json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null \
    || echo "WARN: could not remove syncPolicy.automated"
}

bump_deploy_image() {
  local deploy="$1"
  if ! kubectl get deploy "$deploy" -n "$NAMESPACE" >/dev/null 2>&1; then
    return 1
  fi
  local cname
  cname=$(kubectl get deploy "$deploy" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].name}')
  if [[ -z "$cname" ]]; then
    echo "ERROR: empty container name on deploy/$deploy" >&2
    exit 1
  fi
  echo "kubectl set image deployment/$deploy ${cname}=$FULL_IMAGE -n $NAMESPACE"
  kubectl set image "deployment/$deploy" "${cname}=${FULL_IMAGE}" -n "$NAMESPACE"
  return 0
}

# --- 1) Argo owns the app (typical for all enrolled AM services) ---
if argo_app_exists; then
  echo "Argo Application $ARGO_APP found — image roll via kubectl (no helm install)"
  pause_argo_auto
  if ! bump_deploy_image "$RELEASE_NAME"; then
    echo "ERROR: Argo app $ARGO_APP exists but Deployment/$RELEASE_NAME missing in $NAMESPACE" >&2
    exit 1
  fi
  # Optional companion worker (universal-chart companionWorker)
  bump_deploy_image "${RELEASE_NAME}-worker" || true
  exit 0
fi

# --- 2) Classic Helm release ---
if helm status "$RELEASE_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Helm release exists — upgrade --reuse-values ($FULL_IMAGE)"
  helm upgrade "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --reuse-values \
    --set "global.image.registry=$IMAGE_REGISTRY" \
    --set "global.image.repository=$IMAGE_REPOSITORY" \
    --set "global.image.tag=$IMAGE_TAG" \
    --set "global.image.pullPolicy=Always"
  exit 0
fi

# --- 3) Deploy without Argo/Helm secret (orphan) ---
if kubectl get deploy "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Deployment exists without Argo/Helm — kubectl set image"
  bump_deploy_image "$RELEASE_NAME"
  bump_deploy_image "${RELEASE_NAME}-worker" || true
  exit 0
fi

# --- 4) Greenfield ---
echo "Fresh install via Helm ($FULL_IMAGE)"
SET_LANG=()
if [[ -n "$LANGUAGE" ]]; then
  SET_LANG=(--set "language=$LANGUAGE")
fi
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set "global.image.registry=$IMAGE_REGISTRY" \
  --set "global.image.repository=$IMAGE_REPOSITORY" \
  --set "global.image.tag=$IMAGE_TAG" \
  --set "global.image.pullPolicy=Always" \
  "${SET_LANG[@]}" \
  "${HELM_EXTRA[@]}"
