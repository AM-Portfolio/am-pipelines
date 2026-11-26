#!/usr/bin/env bash
# Upload IPA via altool. Env: IPA_DIR (default ios-out), APP_STORE_CONNECT_API_KEY_ID,
# APP_STORE_CONNECT_API_ISSUER_ID, VERSION_NAME, VERSION_CODE, UPLOAD_MODE=testflight|appstore.
# Optional: BUNDLE_ID (for clearer errors).
set -euo pipefail
IPA_DIR="${IPA_DIR:-ios-out}"
UPLOAD_MODE="${UPLOAD_MODE:-testflight}"

KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-}"
ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-}"

if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ]; then
  echo "::error::ASC upload needs APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID on this GitHub Environment (ios-internal / ios-prod)"
  exit 1
fi

P8_FOUND=""
for dest in \
  "private_keys" \
  "${HOME}/private_keys" \
  "${HOME}/.private_keys" \
  "${HOME}/.appstoreconnect/private_keys"
do
  if [ -s "${dest}/AuthKey_${KEY_ID}.p8" ]; then
    P8_FOUND="${dest}/AuthKey_${KEY_ID}.p8"
    break
  fi
done
if [ -z "$P8_FOUND" ]; then
  echo "::error::AuthKey_${KEY_ID}.p8 not found — run write_asc_key.sh before altool_upload.sh"
  exit 1
fi
echo "Using ASC key file: ${P8_FOUND} (issuer length=${#ISSUER_ID}, keyId=${KEY_ID})"

IPA=$(find "$IPA_DIR" -name "*.ipa" | head -n1)
if [ -z "$IPA" ]; then
  echo "::error::No IPA in ${IPA_DIR} — cannot upload"
  exit 1
fi

set +e
OUT=$(xcrun altool --upload-app --type ios \
  --file "$IPA" \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER_ID" 2>&1)
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
if echo "$OUT" | grep -qiE 'Cannot determine the Apple ID from Bundle ID|ExitFailure \(31\)|\(19\)'; then
  {
    echo "::error::altool could not resolve Apple ID for bundle ${BUNDLE_ID:-unknown} (error 19)."
    echo "::error::Permanent checklist:"
    echo "::error::1) GitHub Environment ios-internal (and ios-prod) must have APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID, APP_STORE_CONNECT_API_KEY_BASE64"
    echo "::error::2) Issuer ID must match the team that owns com.asrax.aminvestment"
    echo "::error::3) ASC API key must be Admin or App Manager with access to that app (Users and Access → Keys)"
    echo "::error::4) AuthKey_${KEY_ID}.p8 must be the matching private key for that Key ID"
  } >&2
fi
echo "::error::altool upload failed (rc=${RC})"
exit "$RC"
