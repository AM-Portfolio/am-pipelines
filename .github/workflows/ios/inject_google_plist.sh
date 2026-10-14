#!/usr/bin/env bash
# Inject GIDClientID + URL schemes into ios/Runner/Info.plist.
# Cwd: Flutter app working_directory. Env: GOOGLE_IOS_CLIENT_ID, GOOGLE_WEB_CLIENT_ID.
set -euo pipefail
PLIST="ios/Runner/Info.plist"
if [ -z "${GOOGLE_IOS_CLIENT_ID:-}" ]; then
  echo "::warning::GOOGLE_IOS_CLIENT_ID empty — leaving Info.plist placeholders"
  exit 0
fi
/usr/libexec/PlistBuddy -c "Set :GIDClientID ${GOOGLE_IOS_CLIENT_ID}" "$PLIST" \
  || /usr/libexec/PlistBuddy -c "Add :GIDClientID string ${GOOGLE_IOS_CLIENT_ID}" "$PLIST"
IOS_SCHEME="com.googleusercontent.apps.${GOOGLE_IOS_CLIENT_ID%.apps.googleusercontent.com}"
WEB_SCHEME=""
if [ -n "${GOOGLE_WEB_CLIENT_ID:-}" ]; then
  WEB_SCHEME="com.googleusercontent.apps.${GOOGLE_WEB_CLIENT_ID%.apps.googleusercontent.com}"
fi
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ${IOS_SCHEME}" "$PLIST"
if [ -n "$WEB_SCHEME" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string ${WEB_SCHEME}" "$PLIST"
fi
echo "Injected GIDClientID and URL schemes into Info.plist"
