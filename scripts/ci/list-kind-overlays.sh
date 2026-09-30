#!/usr/bin/env bash
# List Kind cluster overlay filenames for an env (common across all services).
# Usage: list-kind-overlays.sh <env>
# Prints one filename per line (relative to helm/overlays/nonprod-kind).
# prod → empty (no Kind overlays).
set -euo pipefail

ENV="${1:-${DEPLOY_ENV:-${INPUT_ENVIRONMENT:-}}}"
if [[ -z "$ENV" ]]; then
  echo "Usage: list-kind-overlays.sh <env>" >&2
  exit 1
fi

case "$ENV" in
  preprod)
    printf '%s\n' vault-https-preprod.yaml hostaliases-kind-local.yaml infra-kind-local-env.yaml
    ;;
  dev)
    printf '%s\n' vault-https-asrax.yaml hostaliases-kind-local.yaml infra-kind-local-env.yaml
    ;;
  prod|local)
    ;;
  *)
    echo "ERROR: unknown env '$ENV'" >&2
    exit 1
    ;;
esac
