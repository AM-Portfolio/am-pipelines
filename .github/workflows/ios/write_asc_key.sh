#!/usr/bin/env bash
# Decode ASC .p8 into private_keys/. Env: KEY_BASE64, KEY_ID, PURPOSE (label for errors).
set -euo pipefail
PURPOSE="${PURPOSE:-ASC}"
if [ -z "${KEY_BASE64:-}" ] || [ -z "${KEY_ID:-}" ]; then
  echo "::error::APP_STORE_CONNECT_API_KEY_* secrets required for ${PURPOSE}"
  exit 1
fi
mkdir -p private_keys
echo "$KEY_BASE64" | base64 --decode > "private_keys/AuthKey_${KEY_ID}.p8"
