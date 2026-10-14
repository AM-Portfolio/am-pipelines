#!/usr/bin/env bash
# Upload IPA via altool. Env: IPA_DIR (default ios-out), APP_STORE_CONNECT_API_KEY_ID,
# APP_STORE_CONNECT_API_ISSUER_ID, VERSION_NAME, VERSION_CODE, UPLOAD_MODE=testflight|appstore.
set -euo pipefail
IPA_DIR="${IPA_DIR:-ios-out}"
UPLOAD_MODE="${UPLOAD_MODE:-testflight}"
IPA=$(find "$IPA_DIR" -name "*.ipa" | head -n1)
if [ -z "$IPA" ]; then
  echo "::error::No IPA in ${IPA_DIR} — cannot upload"
  exit 1
fi
set +e
OUT=$(xcrun altool --upload-app --type ios \
  --file "$IPA" \
  --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" 2>&1)
RC=$?
set -e
echo "$OUT"
if [ "$RC" -eq 0 ]; then
  echo "upload_status=uploaded" >> "$GITHUB_OUTPUT"
  if [ "$UPLOAD_MODE" = "appstore" ]; then
    echo "::notice::IPA uploaded for App Store processing (Environment ios-prod approved)"
    echo "### Binary upload"$'\n'"altool upload succeeded for \`${VERSION_NAME}\` (\`${VERSION_CODE}\`)." >> "$GITHUB_STEP_SUMMARY"
  else
    echo "::notice::altool upload succeeded for ${VERSION_NAME} (${VERSION_CODE})"
  fi
  exit 0
fi
if echo "$OUT" | grep -qiE 'already been used|DUPLICATE|must be higher than the previously uploaded version'; then
  echo "upload_status=already_on_asc" >> "$GITHUB_OUTPUT"
  if [ "$UPLOAD_MODE" = "appstore" ]; then
    echo "::notice::Build ${VERSION_CODE} already on ASC — continuing to Submit for Review"
    {
      echo ""
      echo "### Binary upload"
      echo ""
      echo "ASC reported duplicate \`cfBundleVersion\` for \`${VERSION_NAME}\` (\`${VERSION_CODE}\`) — already uploaded."
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
  else
    echo "::notice::Build ${VERSION_CODE} already on ASC — continuing to wait/assign"
  fi
  exit 0
fi
echo "::error::altool upload failed (rc=${RC})"
exit "$RC"
