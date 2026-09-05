#!/usr/bin/env bash
# Bump image for RELEASE_NAME in NAMESPACE.
# - Helm release present → helm upgrade --reuse-values
# - Deployment present (Argo, no Helm secret) → kubectl set image (+ pause Argo auto)
# - Neither → helm upgrade --install with VALUES from "$@" after --
#
# Required env: RELEASE_NAME, NAMESPACE, IMAGE_REGISTRY, IMAGE_REPOSITORY, IMAGE_TAG
# Optional: CHART_DIR, LANGUAGE, PAUSE_ARGO (default true), ARGO_APP (default RELEASE_NAME)
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

FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

HELM_EXTRA=()
if [[ "${1:-}" == "--" ]]; then
  shift
  HELM_EXTRA=("$@")
fi

pause_argo_auto() {
  [[ "$PAUSE_ARGO" == "true" ]] || return 0
  if ! kubectl -n argocd get application "$ARGO_APP" >/dev/null 2>&1; then
    echo "WARN: Argo Application $ARGO_APP missing — skip pause"
    return 0
  fi
  local auto
  auto=$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
  if [[ -z "$auto" || "$auto" == "null" || "$auto" == "{}" ]]; then
    echo "Argo Auto-Sync already off on $ARGO_APP"
    return 0
  fi
  echo "Pausing Argo Auto-Sync on $ARGO_APP (avoid selfHeal reverting CI image)"
  kubectl -n argocd annotate application "$ARGO_APP" \
    "am.asrax.in/ci-paused-auto=true" \
    "am.asrax.in/ci-image=${FULL_IMAGE}" \
    --overwrite >/dev/null || true
  kubectl -n argocd patch application "$ARGO_APP" --type json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null \
    || echo "WARN: could not remove syncPolicy.automated"
}

if helm status "$RELEASE_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Helm release exists — upgrade --reuse-values ($FULL_IMAGE)"
  helm upgrade "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --reuse-values \
    --set "global.image.registry=$IMAGE_REGISTRY" \
    --set "global.image.repository=$IMAGE_REPOSITORY" \
    --set "global.image.tag=$IMAGE_TAG" \
    --set "global.image.pullPolicy=Always"
elif kubectl get deploy "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Deployment exists without Helm release (Argo-owned) — kubectl set image"
  pause_argo_auto
  CNAME=$(kubectl get deploy "$RELEASE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].name}')
  echo "kubectl set image deployment/$RELEASE_NAME ${CNAME}=$FULL_IMAGE"
  kubectl set image "deployment/$RELEASE_NAME" "${CNAME}=${FULL_IMAGE}" -n "$NAMESPACE"
else
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
fi
