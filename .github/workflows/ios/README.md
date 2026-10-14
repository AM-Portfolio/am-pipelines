# iOS Mobile CI helpers

GitHub only auto-runs workflow YAML at `.github/workflows/*.yml` (top level).  
This folder holds **reusable scripts** used by the thin orchestrator [`../central-mobile-ios.yml`](../central-mobile-ios.yml).

Jobs checkout `AM-Portfolio/am-pipelines@main` into `_am_pipelines/` (do not use `github.workflow_sha` under `workflow_call` — that is the **caller** SHA), then run:

```text
bash _am_pipelines/.github/workflows/ios/<script>.sh
python3 _am_pipelines/.github/workflows/ios/<script>.py
```

Also: composite [`.github/actions/checkout-ios-helpers`](../../actions/checkout-ios-helpers/action.yml) (same sparse checkout).

| File | Job | Purpose |
|------|-----|---------|
| `validate_reuse.sh` / `stage_reuse.sh` | `ios-build` | Reuse prior IPA artifact |
| `flutter_prepare.sh` | `ios-build` | doctor, pub get, build_runner |
| `inject_google_plist.sh` | `ios-build` | GIDClientID + URL schemes |
| `sign_import.sh` | `ios-build` | p12+profile or ASC fetch |
| `resolve_version.sh` / `build_ipa.sh` / `stage_ipa.sh` | `ios-build` | version + IPA |
| `write_asc_key.sh` / `altool_upload.sh` / `release_context.sh` | TF / prod | shared upload helpers |
| `asc_client.py` | both ASC scripts | JWT + HTTP |
| `testflight_wait_assign.py` | `ios-internal` | Wait VALID + groups |
| `appstore_submit.py` | `ios-prod` | **Submit for Review** |

## Flow

```text
ios-build (IPA) → ios-internal (altool + wait/assign) → ios-prod (Submit for Review)
```

`ios-prod` is gated by GitHub Environment `ios-prod`.  
Submit for Review needs ASC metadata already complete (screenshots, App Privacy, etc.).
