#!/usr/bin/env bash
# Import Distribution signing (p12+profile or ASC fetch). Cwd: Flutter app dir.
# Env: IOS_CERTIFICATE_*, IOS_PROVISIONING_PROFILE_BASE64, IOS_KEYCHAIN_PASSWORD,
#      CERTIFICATE_PRIVATE_KEY, APP_STORE_CONNECT_API_KEY_*, BUNDLE_ID,
#      DEPLOY_INTERNAL, DEPLOY_PRODUCTION. Sets HAS_SIGNING / SIGNING_MODE / GITHUB_ENV.
set -euo pipefail
NEED_IPA=0
if [ "${DEPLOY_INTERNAL}" = "true" ] || [ "${DEPLOY_PRODUCTION}" = "true" ]; then
  NEED_IPA=1
fi

signing_fail() {
  local msg="$1"
  echo "HAS_SIGNING=0" >> "$GITHUB_ENV"
  if [ "$NEED_IPA" = "1" ]; then
    echo "::error::${msg}"
    exit 1
  fi
  echo "::warning::${msg} — continuing with unsigned build (TestFlight/App Store not requested)"
  exit 0
}

if [ -n "${IOS_CERTIFICATE_BASE64:-}" ] && [ -n "${IOS_PROVISIONING_PROFILE_BASE64:-}" ]; then
  echo "HAS_SIGNING=1" >> "$GITHUB_ENV"
  echo "SIGNING_MODE=p12" >> "$GITHUB_ENV"
  KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
  KEYCHAIN_PASSWORD="${IOS_KEYCHAIN_PASSWORD:-$(uuidgen)}"
  CERT_PATH=$RUNNER_TEMP/build_certificate.p12
  PROFILE_PATH=$RUNNER_TEMP/build_pp.mobileprovision
  echo "$IOS_CERTIFICATE_BASE64" | base64 --decode > "$CERT_PATH"
  echo "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERT_PATH" -P "${IOS_CERTIFICATE_PASSWORD:-}" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
  mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
  PROFILE_PLIST=$(security cms -D -i "$PROFILE_PATH")
  PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< "$PROFILE_PLIST")
  PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" /dev/stdin <<< "$PROFILE_PLIST")
  TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print TeamIdentifier:0" /dev/stdin <<< "$PROFILE_PLIST" 2>/dev/null || echo "7A3JAJ4Y77")
  cp "$PROFILE_PATH" ~/Library/MobileDevice/Provisioning\ Profiles/"$PROFILE_UUID.mobileprovision"
  EXPORT_CI_PLIST="ios/ExportOptions.ci.plist"
  TEAM_ID="$TEAM_ID" BUNDLE_ID="$BUNDLE_ID" PROFILE_NAME="$PROFILE_NAME" EXPORT_CI_PLIST="$EXPORT_CI_PLIST" \
    python3 -c 'import os,plistlib; from pathlib import Path; Path(os.environ["EXPORT_CI_PLIST"]).write_bytes(plistlib.dumps({"method":"app-store","destination":"export","signingStyle":"manual","teamID":os.environ["TEAM_ID"],"provisioningProfiles":{os.environ["BUNDLE_ID"]:os.environ["PROFILE_NAME"]},"stripSwiftSymbols":True,"compileBitcode":False}))'
  echo "PROFILE_UUID=$PROFILE_UUID" >> "$GITHUB_ENV"
  echo "PROFILE_NAME=$PROFILE_NAME" >> "$GITHUB_ENV"
  echo "DEVELOPMENT_TEAM=$TEAM_ID" >> "$GITHUB_ENV"
  echo "EXPORT_OPTIONS_PLIST=$EXPORT_CI_PLIST" >> "$GITHUB_ENV"
  echo "OK: imported p12 + provisioning profile (team=${TEAM_ID} profile=${PROFILE_NAME})"
  exit 0
fi

if [ -n "${IOS_CERTIFICATE_BASE64:-}" ] && [ -z "${IOS_PROVISIONING_PROFILE_BASE64:-}" ]; then
  echo "::notice::IOS_CERTIFICATE_BASE64 set without IOS_PROVISIONING_PROFILE_BASE64 — trying ASC fetch with cert private key"
fi

if [ -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ] && [ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ] && [ -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]; then
  echo "Fetching signing files via ASC API (Codemagic parity)"
  python3 -m venv "$RUNNER_TEMP/asc-venv"
  "$RUNNER_TEMP/asc-venv/bin/pip" install -q 'codemagic-cli-tools'
  export PATH="$RUNNER_TEMP/asc-venv/bin:${PATH}"
  command -v app-store-connect >/dev/null
  mkdir -p "$RUNNER_TEMP/private_keys"
  P8_PATH="$RUNNER_TEMP/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  echo "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$P8_PATH"
  export APP_STORE_CONNECT_KEY_IDENTIFIER="$APP_STORE_CONNECT_API_KEY_ID"
  export APP_STORE_CONNECT_ISSUER_ID="$APP_STORE_CONNECT_API_ISSUER_ID"
  export APP_STORE_CONNECT_PRIVATE_KEY="$(cat "$P8_PATH")"

  CERT_KEY_FILE="$RUNNER_TEMP/private_keys/ios_distribution_private_key.pem"
  CERT_KEY_ARGS=()
  if [ -n "${CERTIFICATE_PRIVATE_KEY:-}" ]; then
    printf '%s\n' "$CERTIFICATE_PRIVATE_KEY" > "$CERT_KEY_FILE"
    CERT_KEY_ARGS=(--certificate-key="@file:${CERT_KEY_FILE}")
    echo "Using CERTIFICATE_PRIVATE_KEY secret for ASC fetch"
  elif [ -n "${IOS_CERTIFICATE_BASE64:-}" ]; then
    P12_PATH="$RUNNER_TEMP/build_certificate.p12"
    echo "$IOS_CERTIFICATE_BASE64" | base64 --decode > "$P12_PATH"
    if openssl pkcs12 -in "$P12_PATH" -nodes -nocerts -passin "pass:${IOS_CERTIFICATE_PASSWORD:-}" -out "$CERT_KEY_FILE" 2>/dev/null \
      || openssl pkcs12 -in "$P12_PATH" -nodes -nocerts -passin "pass:${IOS_CERTIFICATE_PASSWORD:-}" -legacy -out "$CERT_KEY_FILE" 2>/dev/null; then
      if grep -q "PRIVATE KEY" "$CERT_KEY_FILE" 2>/dev/null; then
        CERT_KEY_ARGS=(--certificate-key="@file:${CERT_KEY_FILE}")
        echo "Extracted Distribution private key from IOS_CERTIFICATE_BASE64"
      else
        rm -f "$CERT_KEY_FILE"
        echo "::warning::Could not extract PRIVATE KEY from IOS_CERTIFICATE_BASE64 (wrong IOS_CERTIFICATE_PASSWORD?)"
      fi
    else
      echo "::warning::openssl could not open IOS_CERTIFICATE_BASE64 — set IOS_CERTIFICATE_PASSWORD or CERTIFICATE_PRIVATE_KEY"
    fi
  fi

  if [ ${#CERT_KEY_ARGS[@]} -eq 0 ]; then
    ssh-keygen -t rsa -b 2048 -m PEM -f "$CERT_KEY_FILE" -q -N ""
    CERT_KEY_ARGS=(--certificate-key="@file:${CERT_KEY_FILE}")
    echo "::notice::No CERTIFICATE_PRIVATE_KEY / extractable p12 key — generated ephemeral RSA key for ASC --create"
  fi

  keychain initialize
  set +e
  FETCH_OUT=$(app-store-connect fetch-signing-files "$BUNDLE_ID" --type IOS_APP_STORE --create "${CERT_KEY_ARGS[@]}" 2>&1)
  FETCH_RC=$?
  set -e
  echo "$FETCH_OUT"
  if [ "$FETCH_RC" -ne 0 ]; then
    signing_fail "ASC fetch-signing-files failed (rc=${FETCH_RC}). Likely: Distribution cert exists without a matching private key. Set CERTIFICATE_PRIVATE_KEY (PEM) or IOS_CERTIFICATE_BASE64+IOS_CERTIFICATE_PASSWORD+IOS_PROVISIONING_PROFILE_BASE64. See https://help.codemagic.io/articles/6381361596-why-am-i-getting-cannot-create-resource-without-certificate-private-key-during-ios-automatic-code-signing"
  fi
  keychain add-certificates
  xcode-project use-profiles
  echo "HAS_SIGNING=1" >> "$GITHUB_ENV"
  echo "SIGNING_MODE=asc_fetch" >> "$GITHUB_ENV"
  echo "OK: ASC fetch-signing-files for ${BUNDLE_ID}"
  exit 0
fi

signing_fail "iOS signing unavailable. Set IOS_CERTIFICATE_BASE64 + IOS_PROVISIONING_PROFILE_BASE64, or APP_STORE_CONNECT_API_KEY_* (+ CERTIFICATE_PRIVATE_KEY)."
