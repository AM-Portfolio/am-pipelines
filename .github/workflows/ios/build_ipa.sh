#!/usr/bin/env bash
# Build signed IPA or unsigned .app. Cwd: Flutter app.
# Env: AM_DOMAIN, AM_ENV_LABEL, VERSION_NAME, VERSION_CODE, AM_GOOGLE_*, AM_GROWTHBOOK_*,
#      HAS_SIGNING, EXPORT_OPTIONS_PLIST, DEVELOPMENT_TEAM, PROFILE_UUID, PROFILE_NAME.
set -euo pipefail
if [ -L build ] || [ -f build ]; then rm -rf build; fi
EXTRA=()
if [ -n "${AM_DOMAIN:-}" ]; then EXTRA+=(--dart-define="AM_DOMAIN=${AM_DOMAIN}"); fi
if [ -n "${AM_ENV_LABEL:-}" ]; then EXTRA+=(--dart-define="AM_ENV=${AM_ENV_LABEL}"); fi
if [ -n "${AM_GOOGLE_CLIENT_ID:-}" ]; then EXTRA+=(--dart-define="AM_GOOGLE_CLIENT_ID=${AM_GOOGLE_CLIENT_ID}"); fi
if [ -n "${AM_GOOGLE_IOS_CLIENT_ID:-}" ]; then EXTRA+=(--dart-define="AM_GOOGLE_IOS_CLIENT_ID=${AM_GOOGLE_IOS_CLIENT_ID}"); fi
if [ -n "${AM_GROWTHBOOK_CLIENT_KEY:-}" ]; then EXTRA+=(--dart-define="AM_GROWTHBOOK_CLIENT_KEY=${AM_GROWTHBOOK_CLIENT_KEY}"); fi
EXPORT_OPTS=()
if [ "${HAS_SIGNING:-0}" = "1" ]; then
  EXPORT_PLIST="${EXPORT_OPTIONS_PLIST:-ios/ExportOptions.plist}"
  if [ ! -f "$EXPORT_PLIST" ]; then
    EXPORT_PLIST=ios/ExportOptions.plist
  fi
  EXPORT_OPTS+=(--export-options-plist="$EXPORT_PLIST")
  TEAM="${DEVELOPMENT_TEAM:-7A3JAJ4Y77}"
  mkdir -p ios/Flutter
  {
    echo "CODE_SIGN_STYLE=Manual"
    echo "DEVELOPMENT_TEAM=${TEAM}"
    echo "CODE_SIGN_IDENTITY=Apple Distribution"
    echo "CODE_SIGN_IDENTITY[sdk=iphoneos*]=Apple Distribution"
    if [ -n "${PROFILE_UUID:-}" ]; then
      echo "PROVISIONING_PROFILE=${PROFILE_UUID}"
    fi
    if [ -n "${PROFILE_NAME:-}" ]; then
      echo "PROVISIONING_PROFILE_SPECIFIER=${PROFILE_NAME}"
    fi
  } >> ios/Flutter/Release.xcconfig
  echo "Injected Manual Distribution signing into ios/Flutter/Release.xcconfig (team=${TEAM})"
else
  flutter build ios --no-codesign \
    --build-name="${VERSION_NAME}" \
    --build-number="${VERSION_CODE}" \
    ${EXTRA[@]+"${EXTRA[@]}"}
  mkdir -p "$GITHUB_WORKSPACE/ios-ci-out"
  APP_PATH=$(find build/ios/iphoneos -name "*.app" 2>/dev/null | head -n1)
  if [ -n "$APP_PATH" ]; then
    cp -R "$APP_PATH" "$GITHUB_WORKSPACE/ios-ci-out/"
  fi
  echo "UNSIGNED=1" >> "$GITHUB_ENV"
  exit 0
fi
flutter build ipa --release \
  --build-name="${VERSION_NAME}" \
  --build-number="${VERSION_CODE}" \
  ${EXPORT_OPTS[@]+"${EXPORT_OPTS[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"}
echo "UNSIGNED=0" >> "$GITHUB_ENV"
