# iOS Mobile CI helpers

GitHub only auto-runs workflow YAML at `.github/workflows/*.yml` (top level).  
This folder holds **Python helpers** used by [`../central-mobile-ios.yml`](../central-mobile-ios.yml).

| File | Used by | Purpose |
|------|---------|---------|
| `asc_client.py` | both scripts | ASC JWT + HTTP |
| `testflight_wait_assign.py` | `ios-internal` | Wait VALID, export compliance, TestFlight groups |
| `appstore_submit.py` | `ios-prod` | Attach build + **Submit for Review** |

## Flow

```text
ios-build (IPA) → ios-internal (altool + wait/assign) → ios-prod (Submit for Review)
```

`ios-prod` is gated by the GitHub Environment `ios-prod`.  
Submit for Review needs ASC metadata already complete (screenshots, App Privacy, etc.).
