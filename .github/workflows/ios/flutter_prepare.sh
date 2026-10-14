#!/usr/bin/env bash
# Flutter doctor, disable SPM, pub get + build_runner across the monorepo.
# Run from github.workspace (caller repo root).
set -euo pipefail
flutter doctor -v
flutter config --no-enable-swift-package-manager
find . -name "pubspec.yaml" -not -path "*/.*" | while read -r file; do
  dir=$(dirname "$file")
  (cd "$dir" && flutter pub get)
done
while IFS= read -r file; do
  dir=$(dirname "$file")
  if grep -q "build_runner" "$dir/pubspec.yaml"; then
    echo "Running build_runner in $dir..."
    (cd "$dir" && dart run build_runner build --delete-conflicting-outputs)
  fi
done < <(find . -name "pubspec.yaml" -not -path "*/.*")
