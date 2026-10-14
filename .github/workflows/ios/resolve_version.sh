#!/usr/bin/env bash
# Resolve marketing version + CFBundleVersion from pubspec + run_number.
# Cwd: Flutter app. Env: RUN_NUMBER, BUNDLE_ID, AM_ENV. Writes GITHUB_OUTPUT + summary.
set -euo pipefail
RAW=$(grep -E '^version:' pubspec.yaml | head -n1 | sed -E 's/^version:[[:space:]]*//')
RAW=${RAW//$'\r'/}
NAME=${RAW%%+*}
BUILD=${RAW##*+}
if [ "$NAME" = "$RAW" ] || [ -z "$BUILD" ] || ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  BUILD=0
fi
if [ -z "$NAME" ]; then NAME="0.0.0"; fi
RUN_NUMBER="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
CODE=$(( BUILD + RUN_NUMBER ))
echo "version_name=$NAME" >> "$GITHUB_OUTPUT"
echo "version_code=$CODE" >> "$GITHUB_OUTPUT"
SHORT_SHA="${GITHUB_SHA:0:7}"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
{
  echo "## iOS build version"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Marketing version | \`${NAME}\` |"
  echo "| Build number (CFBundleVersion) | \`${CODE}\` |"
  echo "| pubspec | \`${RAW}\` |"
  echo "| Run number | \`${RUN_NUMBER}\` |"
  echo "| SHA | \`${SHORT_SHA}\` |"
  echo "| Bundle ID | \`${BUNDLE_ID:-}\` |"
  echo "| AM_ENV | \`${AM_ENV:-}\` |"
  echo "| Resolved at (UTC) | \`${TS_UTC}\` |"
} >> "$GITHUB_STEP_SUMMARY"
echo "::notice::iOS version ${NAME} (${CODE}) run=${RUN_NUMBER} sha=${SHORT_SHA} env=${AM_ENV:-} @ ${TS_UTC}"
