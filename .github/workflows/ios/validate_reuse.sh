#!/usr/bin/env bash
# Validate skip_ios_build reuse inputs. Env: REUSE_ARTIFACT_RUN_ID, REUSE_ARTIFACT_NAME,
# REUSE_VERSION_NAME, REUSE_VERSION_CODE.
set -euo pipefail
if [ -z "${REUSE_ARTIFACT_RUN_ID:-}" ] || [ -z "${REUSE_ARTIFACT_NAME:-}" ]; then
  echo "::error::skip_ios_build requires reuse_artifact_run_id and reuse_artifact_name"
  exit 1
fi
if [ -z "${REUSE_VERSION_NAME:-}" ] || [ -z "${REUSE_VERSION_CODE:-}" ]; then
  echo "::error::skip_ios_build requires reuse_version_name and reuse_version_code (must match IPA)"
  exit 1
fi
