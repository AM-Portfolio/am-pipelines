#!/usr/bin/env bash
# Stage reused IPA version outputs + job summary.
# Env: REUSE_VERSION_NAME, REUSE_VERSION_CODE, REUSE_ARTIFACT_RUN_ID, REUSE_ARTIFACT_NAME,
#      BUNDLE_ID, AM_ENV, RUN_NUMBER (optional; defaults from GITHUB_*).
set -euo pipefail
NAME="${REUSE_VERSION_NAME}"
CODE="${REUSE_VERSION_CODE}"
IPA=$(find ios-ci-out -name "*.ipa" | head -n1)
if [ -z "$IPA" ]; then
  echo "::error::No .ipa in reused artifact ${REUSE_ARTIFACT_NAME}"
  find ios-ci-out -type f | head -50 || true
  exit 1
fi
echo "version_name=$NAME" >> "$GITHUB_OUTPUT"
echo "version_code=$CODE" >> "$GITHUB_OUTPUT"
SHORT_SHA="${GITHUB_SHA:0:7}"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
RUN_NUMBER="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
{
  echo "## iOS build version (reused artifact)"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Marketing version | \`${NAME}\` |"
  echo "| Build number (CFBundleVersion) | \`${CODE}\` |"
  echo "| Source run | \`${REUSE_ARTIFACT_RUN_ID}\` |"
  echo "| Source artifact | \`${REUSE_ARTIFACT_NAME}\` |"
  echo "| Run number | \`${RUN_NUMBER}\` |"
  echo "| SHA | \`${SHORT_SHA}\` |"
  echo "| Bundle ID | \`${BUNDLE_ID:-}\` |"
  echo "| AM_ENV | \`${AM_ENV:-}\` |"
  echo "| Resolved at (UTC) | \`${TS_UTC}\` |"
} >> "$GITHUB_STEP_SUMMARY"
echo "::notice::Reusing IPA ${NAME} (${CODE}) from run ${REUSE_ARTIFACT_RUN_ID} / ${REUSE_ARTIFACT_NAME}"
ls -la ios-ci-out
