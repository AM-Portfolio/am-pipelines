# Library publish on `main`

## Reusable workflow

`am-pipelines/.github/workflows/publish-library.yml` — called by service repos.

| Language | Output | Version on `main` |
|----------|--------|-------------------|
| `java` | GitHub Packages Maven | `-SNAPSHOT` stripped via `versions-maven-plugin` |
| `python` | GitHub Release (wheel) | From `pyproject.toml` |
| `flutter` | GitHub Release (zip) | From `pubspec.yaml` |

Inputs:

- `action`: `publish` (deploy/release) or `verify` (build/test only, no registry push)
- `use_release_version`: caller may request Java `-SNAPSHOT` removal; the reusable workflow applies it **only** on `refs/heads/main`

## Release version logic

Final Java versions (no `-SNAPSHOT`) are created **only** when code is on `refs/heads/main` at publish time.

**Enforcement (reusable workflow)** — `am-pipelines/.github/workflows/publish-library.yml`:

- Lines **162–166**: step `Promote to release version (strip SNAPSHOT, CI only)` runs only when all of the following are true:
  - `inputs.language == 'java'`
  - `inputs.action == 'publish'`
  - `inputs.use_release_version`
  - `github.ref == 'refs/heads/main'`

Even if a caller passes `use_release_version: true` from a feature branch or PR, the strip step is skipped.

**Callers**

| Workflow | Trigger | Release strip on Java |
|----------|---------|------------------------|
| `am-core-services/.github/workflows/core-libraries-publish.yml` | `push` → `main` only (lines **7–9**) | `use_release_version: true` (line **63**) |
| `am-market/.github/workflows/am-sdk-publish.yml` | `push` / `pull_request` on SDK paths | `use_release_version` only when `github.ref == 'refs/heads/main'`; PRs use `action: verify` |
| `am-market/.github/workflows/market-common-lib.yml` | `push` to many branches; PR verify | `use_release_version` only on `main`; other branches publish **with** `-SNAPSHOT` |

## am-core-services

`am-core-services/.github/workflows/core-libraries-publish.yml` runs on push to `main` when `libraries/**` changes:

- **Java**: deploys all library modules from repo root (`mvn deploy`) to `https://maven.pkg.github.com/AM-Portfolio/am-core-services`
- **Flutter**: `libraries/am-sdk-verifier/flutter-verifier` when that path changes

## Other repos

See `am-market/.github/workflows/am-sdk-publish.yml` and `market-common-lib.yml` for Java/Python/Flutter SDK publish patterns.
