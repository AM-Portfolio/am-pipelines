#!/usr/bin/env bash
# Write release job summary. Env: TITLE, VERSION_NAME, VERSION_CODE, ARTIFACT_NAME,
# BUNDLE_ID, AM_ENV, EXTRA_ROW_LABEL, EXTRA_ROW_VALUE (optional), NOTICE_PREFIX.
set -euo pipefail
SHORT_SHA="${GITHUB_SHA:0:7}"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
RUN_NUMBER="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
{
  echo "## ${TITLE}"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Marketing version | \`${VERSION_NAME}\` |"
  echo "| Build number | \`${VERSION_CODE}\` |"
  echo "| Artifact | \`${ARTIFACT_NAME}\` |"
  if [ -n "${EXTRA_ROW_LABEL:-}" ]; then
    echo "| ${EXTRA_ROW_LABEL} | \`${EXTRA_ROW_VALUE:-}\` |"
  fi
  echo "| Run number | \`${RUN_NUMBER}\` |"
  echo "| SHA | \`${SHORT_SHA}\` |"
  echo "| Bundle ID | \`${BUNDLE_ID:-}\` |"
  echo "| AM_ENV | \`${AM_ENV:-}\` |"
  echo "| Job start (UTC) | \`${TS_UTC}\` |"
} >> "$GITHUB_STEP_SUMMARY"
echo "::notice::${NOTICE_PREFIX:-Release} ${VERSION_NAME} (${VERSION_CODE}) artifact=${ARTIFACT_NAME} sha=${SHORT_SHA}"
