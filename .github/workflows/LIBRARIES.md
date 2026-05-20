# Library publish workflows

## Reusable workflow

`publish-library.yml` is called from service repos (e.g. `am-market`, `am-core-services`).

| Input | Default | Description |
|-------|---------|-------------|
| `language` | — | `java`, `python`, or `flutter` |
| `working_directory` | — | Path to the library/SDK |
| `action` | `publish` | `publish` = deploy/release; `verify` = build/test only (PRs) |
| `use_release_version` | `false` | When `true`, strips `-SNAPSHOT` before Java `mvn deploy` (CI only; pom in git unchanged) |

### Versioning (Java)

- Develop/PR: keep `1.0.0-SNAPSHOT` from `pom.xml`; PR workflows should use `action: verify`.
- **main/master merge**: set `use_release_version: true` → publishes `1.0.0` (no SNAPSHOT suffix) to GitHub Packages.

### Registries

- Java: `distributionManagement` in the project POM (`github`, `github-core`, `github-investment`, …).
- Python / Flutter: GitHub Releases (`.whl` or `.zip`); pip/pub registries are not used for private packages.

## am-core-services

`am-core-services/.github/workflows/core-libraries-publish.yml`:

- **PR**: reactor `mvn verify` on changed modules only (`-pl … -am`).
- **push to `main` or `master`**: path-filtered publish of libraries (and dependent domain modules) with `use_release_version: true`.
