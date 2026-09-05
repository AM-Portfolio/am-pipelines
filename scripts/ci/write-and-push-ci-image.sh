#!/usr/bin/env bash
# Write helm/ci-image.yaml with the CI image tag and push to the current feature branch.
# Argo values source on that branch picks it up last (overrides image-tags).
#
# Env: INPUT_WORKING_DIRECTORY, IMAGE_TAG (or RUN_ID), INPUT_GIT_REF
# Optional: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL
set -euo pipefail

WD="${INPUT_WORKING_DIRECTORY:-.}"
TAG="${IMAGE_TAG:-${RUN_ID:?IMAGE_TAG or RUN_ID required}}"
REF="${INPUT_GIT_REF:?INPUT_GIT_REF required}"

if [[ "$REF" == "main" || "$REF" == "master" ]]; then
  echo "Skip ci-image push on $REF (main uses am-gitops image-tags)"
  exit 0
fi

HELM_DIR="$WD/helm"
mkdir -p "$HELM_DIR"
FILE="$HELM_DIR/ci-image.yaml"

cat > "$FILE" <<EOF
# Written by CI for feature-branch preprod rolls. Do not commit on main.
# Last valueFile in Argo Application — overrides am-gitops image-tags while values revision is this branch.
global:
  image:
    tag: "${TAG}"
EOF

echo "Wrote $FILE tag=$TAG"

git config user.name "${GIT_AUTHOR_NAME:-am-ci-bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-ci-bot@asrax.in}"

# Ensure we are on REF (checkout may be detached)
git fetch origin "$REF" --depth=1 || true
git checkout -B "$REF" "origin/$REF" 2>/dev/null || git checkout -B "$REF"

git add "$FILE"
if git diff --cached --quiet; then
  echo "No change to $FILE"
  exit 0
fi

git commit -m "ci(preprod): set image tag ${TAG} for feature roll"
git push origin "HEAD:refs/heads/${REF}"
echo "OK: pushed $FILE to origin/$REF"
