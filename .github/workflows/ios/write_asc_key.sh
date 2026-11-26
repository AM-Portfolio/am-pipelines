#!/usr/bin/env bash
# Decode ASC .p8 into every path altool / ContentDelivery searches.
# Env: KEY_BASE64, KEY_ID, PURPOSE (label for errors). Optional: ISSUER_ID (validated when set).
set -euo pipefail
PURPOSE="${PURPOSE:-ASC}"
if [ -z "${KEY_BASE64:-}" ] || [ -z "${KEY_ID:-}" ]; then
  echo "::error::APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_KEY_BASE64 required for ${PURPOSE}"
  exit 1
fi
if [ -n "${ISSUER_ID+x}" ] && [ -z "${ISSUER_ID}" ]; then
  echo "::error::APP_STORE_CONNECT_API_ISSUER_ID is empty for ${PURPOSE} (set it on the GitHub Environment)"
  exit 1
fi

TMP_P8="$(mktemp)"
cleanup() { rm -f "$TMP_P8"; }
trap cleanup EXIT

echo "$KEY_BASE64" | tr -d '\r\n ' | base64 --decode > "$TMP_P8"
if [ ! -s "$TMP_P8" ]; then
  echo "::error::Decoded AuthKey_${KEY_ID}.p8 is empty — check APP_STORE_CONNECT_API_KEY_BASE64"
  exit 1
fi
# PEM-ish sanity (ASC .p8 starts with BEGIN PRIVATE KEY)
if ! grep -q "BEGIN PRIVATE KEY" "$TMP_P8"; then
  echo "::error::AuthKey_${KEY_ID}.p8 does not look like a valid .p8 (missing BEGIN PRIVATE KEY)"
  exit 1
fi

# Apple searches several dirs; Xcode 16+/26 ContentDelivery is picky — install all of them.
DESTS=(
  "private_keys"
  "${HOME}/private_keys"
  "${HOME}/.private_keys"
  "${HOME}/.appstoreconnect/private_keys"
)
for dest in "${DESTS[@]}"; do
  mkdir -p "$dest"
  cp "$TMP_P8" "${dest}/AuthKey_${KEY_ID}.p8"
  chmod 600 "${dest}/AuthKey_${KEY_ID}.p8"
done

echo "::notice::Wrote AuthKey_${KEY_ID}.p8 for ${PURPOSE} (cwd + ~/.appstoreconnect/private_keys + ~/private_keys)"
