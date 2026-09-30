#!/usr/bin/env bash
# RETIRED — writing helm/ci-image.yaml onto the feature branch retriggered CI
# (path filters include helm/** → new run_id → new commit → loop).
#
# Feature images stay in GHCR only. Preprod/dev roll via am-gitops image-tags
# + Contabo Argo. Main merge auto-pins when digest changes.
#
# Env ignored. Always exits 0 so old callers do not fail.
set -euo pipefail
echo "::notice::write-and-push-ci-image.sh is retired (no service-repo bot commits)."
echo "::notice::Use GHCR tag from the build + am-gitops pin / Contabo Argo sync."
exit 0
