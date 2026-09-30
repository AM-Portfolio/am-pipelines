#!/usr/bin/env bash
# Select kubeconfig for BREAK-GLASS Helm only (force_preprod_helm / legacy).
# Fleet enrolled services must NOT use this — use Argo API sync instead.
#
# Usage: select-cluster-kubeconfig.sh <dev|preprod|prod>
# Policy: refuse GitHub-stored base64 kubeconfigs (KUBECONFIG_*_B64).
# Only runner-local KUBECONFIG file is allowed for break-glass.
set -euo pipefail

ROLE="${1:?usage: select-cluster-kubeconfig.sh <dev|preprod|prod>}"

case "$ROLE" in
  dev|preprod)
    if [[ -n "${KUBECONFIG_NONPROD_B64:-}" ]]; then
      echo "::error::Refuse GitHub secret KUBECONFIG_NONPROD. Fleet deploy uses Argo API only."
      echo "::error::For break-glass Helm, mount kubeconfig on the self-hosted runner (KUBECONFIG file), never as a repo secret."
      exit 1
    fi
    ;;
  prod)
    if [[ -n "${KUBECONFIG_PROD_B64:-}" ]]; then
      echo "::error::Refuse GitHub secret KUBECONFIG_PROD. Prod deploys via promote PR + Argo sync only."
      echo "::error::Do not store Contabo kubeconfig in GitHub."
      exit 1
    fi
    ;;
  *)
    echo "Unknown role: $ROLE (expected dev|preprod|prod)"
    exit 1
    ;;
esac

OUT="${RUNNER_TEMP:-/tmp}/kubeconfig-${ROLE}-$$"
if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
  cp "$KUBECONFIG" "$OUT"
  echo "Break-glass: reusing runner-local KUBECONFIG=${KUBECONFIG}"
else
  echo "::error::No runner-local kubeconfig for ${ROLE}."
  echo "Fleet path: pin in am-gitops + Argo API (ARGOCD_AUTH_TOKEN). Do not put kubeconfig in GitHub secrets."
  exit 1
fi

chmod 600 "$OUT"
export KUBECONFIG="$OUT"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "KUBECONFIG=${OUT}" >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "kubeconfig_path=${OUT}" >> "$GITHUB_OUTPUT"
fi
