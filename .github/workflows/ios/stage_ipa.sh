#!/usr/bin/env bash
# Copy IPA (or leave unsigned .app) into ios-ci-out and set artifact_name.
# Env: BUILD_MODE, RUN_ID (optional), UNSIGNED.
set -euo pipefail
ARTIFACT_NAME="ios-${BUILD_MODE:-release}-${RUN_ID:-${GITHUB_RUN_ID}}"
echo "artifact_name=$ARTIFACT_NAME" >> "$GITHUB_OUTPUT"
mkdir -p "$GITHUB_WORKSPACE/ios-ci-out"
if [ "${UNSIGNED:-0}" != "1" ]; then
  SRC=$(find build/ios/ipa -name "*.ipa" 2>/dev/null | head -n1)
  if [ -z "$SRC" ]; then
    echo "ERROR: No .ipa found under build/ios/ipa"
    find build/ios -type f 2>/dev/null | head -50 || true
    exit 1
  fi
  cp "$SRC" "$GITHUB_WORKSPACE/ios-ci-out/"
fi
ls -la "$GITHUB_WORKSPACE/ios-ci-out"
