#!/usr/bin/env bash
# Resolve Helm release name from env-agnostic base (.am.yaml / image_name).
#
# Usage:
#   resolve-helm-release.sh <base> <env>
#   RELEASE_BASE=... DEPLOY_ENV=... resolve-helm-release.sh
#
# Rules (match Kind/Contabo Argo):
#   prod    → bare base (strip accidental -prod)
#   preprod → base-preprod (idempotent)
#   dev     → base-dev (idempotent)
#
# Prints release name on stdout. Also prints stripped image base on stderr
# when RESOLVE_HELM_VERBOSE=1.
set -euo pipefail

BASE="${1:-${RELEASE_BASE:-${INPUT_SERVICE_NAME:-${INPUT_IMAGE_NAME:-}}}}"
ENV="${2:-${DEPLOY_ENV:-${INPUT_ENVIRONMENT:-}}}"

if [[ -z "$BASE" || -z "$ENV" ]]; then
  echo "Usage: resolve-helm-release.sh <base> <env>" >&2
  echo "  or set RELEASE_BASE/INPUT_SERVICE_NAME and DEPLOY_ENV/INPUT_ENVIRONMENT" >&2
  exit 1
fi

# Strip env suffixes so callers can pass either base or already-suffixed names.
strip_base() {
  local b="$1"
  b="${b%-preprod}"
  b="${b%-dev}"
  b="${b%-prod}"
  printf '%s' "$b"
}

BASE="$(strip_base "$BASE")"

case "$ENV" in
  prod)
    RELEASE="$BASE"
    ;;
  preprod)
    RELEASE="${BASE}-preprod"
    ;;
  dev)
    RELEASE="${BASE}-dev"
    ;;
  *)
    echo "ERROR: unknown env '$ENV' (expected prod|preprod|dev)" >&2
    exit 1
    ;;
esac

if [[ "${RESOLVE_HELM_VERBOSE:-0}" == "1" ]]; then
  echo "resolve-helm-release: env=$ENV base=$BASE release=$RELEASE" >&2
fi

printf '%s\n' "$RELEASE"
