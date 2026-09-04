#!/usr/bin/env bash
# Select kubeconfig for CI Helm rolls.
# Usage: select-cluster-kubeconfig.sh <dev|preprod|prod>
# Env: KUBECONFIG_NONPROD_B64, KUBECONFIG_PROD_B64 (optional base64 kubeconfigs)
set -euo pipefail

ENV="${1:?usage: $0 <dev|preprod|prod>}"

case "$ENV" in
  dev|preprod)
    ROLE=nonprod
    EXPECT_NS="am-apps-${ENV}"
    B64="${KUBECONFIG_NONPROD_B64:-}"
    SECRET_NAME=KUBECONFIG_NONPROD
    ;;
  prod)
    ROLE=prod
    EXPECT_NS=am-apps-prod
    B64="${KUBECONFIG_PROD_B64:-}"
    SECRET_NAME=KUBECONFIG_PROD
    ;;
  *)
    echo "Unsupported environment: $ENV (expected dev|preprod|prod)"
    exit 1
    ;;
esac

OUT="${RUNNER_TEMP:-/tmp}/kubeconfig-${ROLE}-$$"
if [ -n "${B64}" ]; then
  echo "$B64" | base64 -d > "$OUT"
  chmod 600 "$OUT"
  echo "Wrote kubeconfig from secret ${SECRET_NAME}"
elif [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
  cp "$KUBECONFIG" "$OUT"
  chmod 600 "$OUT"
  echo "Reusing runner KUBECONFIG=${KUBECONFIG}"
elif [ -f "${HOME}/.kube/config" ]; then
  cp "${HOME}/.kube/config" "$OUT"
  chmod 600 "$OUT"
  echo "Reusing ~/.kube/config (runner must be on ${ROLE} VPS)"
else
  echo "No kubeconfig for ${ROLE}."
  echo "Set GitHub Actions secret ${SECRET_NAME} (base64 kubeconfig),"
  echo "or run this job on a self-hosted runner labeled for that cluster"
  echo "(vps-nonprod for dev/preprod, vps-prod for prod)."
  exit 1
fi

export KUBECONFIG="$OUT"
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
CONTEXT=$(kubectl config current-context 2>/dev/null || true)
echo "cluster_role=${ROLE}"
echo "context=${CONTEXT}"
echo "server=${SERVER}"

if [ "$ROLE" = "nonprod" ]; then
  if echo "$SERVER" | grep -Eq '203\.174\.22\.129:6443'; then
    echo "Refusing nonprod deploy against Contabo prod API (${SERVER})."
    echo "Point KUBECONFIG_NONPROD at am-vps-nonprod (ITSmart Kind)."
    exit 1
  fi
  if ! kubectl get ns "$EXPECT_NS" >/dev/null 2>&1; then
    echo "Cannot access namespace ${EXPECT_NS} on this cluster (server=${SERVER})."
    exit 1
  fi
else
  if ! kubectl get ns am-apps-prod >/dev/null 2>&1; then
    echo "Cannot access namespace am-apps-prod on prod kubeconfig (server=${SERVER})."
    exit 1
  fi
  if echo "$SERVER" | grep -Eq '127\.0\.0\.1:16443|localhost:16443'; then
    echo "Refusing prod deploy against Kind localhost API (${SERVER})."
    exit 1
  fi
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "KUBECONFIG=${OUT}" >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "cluster_role=${ROLE}" >> "$GITHUB_OUTPUT"
  echo "kubeconfig_path=${OUT}" >> "$GITHUB_OUTPUT"
fi

echo "Selected ${ROLE} cluster for ${ENV} (ns ok: ${EXPECT_NS})"
