# Central mobile CI — Android / iOS (am-pipelines)

Reusable workflows called by **am-modern-ui** [`mobile-ci.yml`](https://github.com/AM-Portfolio/am-modern-ui/blob/main/.github/workflows/mobile-ci.yml).

| Workflow | Path |
|----------|------|
| Central Mobile Android | [`.github/workflows/central-mobile-android.yml`](../.github/workflows/central-mobile-android.yml) |
| Central Mobile iOS | [`.github/workflows/central-mobile-ios.yml`](../.github/workflows/central-mobile-ios.yml) |

Web Contabo (including Google/GrowthBook helm inject on roll) is [`.github/workflows/central-build-publish-contabo.yml`](../.github/workflows/central-build-publish-contabo.yml) + `INPUT_EXTRA_HELM_PARAMS` in [`scripts/ci/argo-roll-image-and-wait.sh`](../scripts/ci/argo-roll-image-and-wait.sh). Universal-chart ConfigMap: [`helm/universal-chart/templates/configmap.yaml`](../helm/universal-chart/templates/configmap.yaml).

Caller SoT for secrets list and “how to get files”: **am-modern-ui** [`docs/MOBILE_CI_CD.md`](https://github.com/AM-Portfolio/am-modern-ui/blob/main/docs/MOBILE_CI_CD.md).

---

## Inputs (deploy gating)

Callers set deploy flags **false** on non-`main` branches.

### Android

- `deploy_internal` / `deploy_preprod` → Play **internal** track (`android-internal` env) — **uploads** the AAB
- `deploy_production` / `deploy_prod` → Play **production** (`android-prod` env): **promotes** the same `versionCode` from Internal (no AAB re-upload). If Internal was skipped, uploads the AAB to production instead.
- Re-uploading the same AAB to production after Internal fails with Play error `Version code N has already been used` — use promote (`scripts/ci/_play_promote_track.py`).
- Build always uploads AAB/APK artifact when `upload_artifact: true`
- Dart-defines from secrets: `AM_GOOGLE_CLIENT_ID`, `AM_GOOGLE_IOS_CLIENT_ID`, `AM_GOOGLE_ANDROID_CLIENT_ID`, `AM_GROWTHBOOK_CLIENT_KEY` (+ `am_domain` / `am_env` inputs)

### iOS

- `deploy_internal` → TestFlight (`ios-internal`)
- `deploy_production` → App Store path after TestFlight (`ios-prod`)
- Injects `GIDClientID` + URL schemes from `GOOGLE_IOS_CLIENT_ID` / `GOOGLE_WEB_CLIENT_ID`
- Without `IOS_CERTIFICATE_BASE64` + profile: build may produce unsigned app artifact only (no store upload)

---

## Secrets expected from caller (`secrets: inherit`)

Secrets are defined on the **caller** repo (`am-modern-ui`), not on am-pipelines.

**Android:** `ANDROID_KEYSTORE_*`, `PLAY_STORE_SERVICE_ACCOUNT_JSON`, `GOOGLE_*`, `GROWTHBOOK_CLIENT_KEY`

**iOS:** `IOS_CERTIFICATE_*`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_KEYCHAIN_PASSWORD`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_BASE64`, `GOOGLE_*`, `GROWTHBOOK_CLIENT_KEY`

**Web Contabo (optional inherit):** same `GOOGLE_*` + `GROWTHBOOK_CLIENT_KEY` → helm params `appConfig.googleWebClientId` / `googleIosClientId` / `googleAndroidClientId` / `appConfig.growthbook.clientKey` when pin→roll runs.

---

## Operator steps

1. Keep this feature branch (or merge to `main`) so callers’ `uses: …@ref` resolve.
2. On am-modern-ui: set secrets + Environments per [MOBILE_CI_CD.md](https://github.com/AM-Portfolio/am-modern-ui/blob/main/docs/MOBILE_CI_CD.md).
3. Point modern-ui `uses:` / `pipelines_ref` at this branch while iterating; flip to `@main` after merge.
4. Verify: feature push → build jobs only; `main` → Internal then Production/App Store after env approval.

SSH is not used for store deploy.
