#!/usr/bin/env bash
set -euo pipefail
cd /f/am-repos/am-repos/am-pipelines
"C:/Program Files/Git/bin/bash.exe" -n scripts/ci/argo-api-lib.sh
"C:/Program Files/Git/bin/bash.exe" -n scripts/ci/argo-roll-image-and-wait.sh
git add scripts/ci/argo-api-lib.sh scripts/ci/argo-roll-image-and-wait.sh
printf '%s\n' 'fix(ci): Contabo dig/preprod roll sync with sources override + fix tag evidence' '' 'summary.images was empty while syncResult still showed the old gitops pin; sync now passes helm.parameters in the Sync request and wait reads syncResult.resources images.' > /tmp/cmsg2.txt
set +e
git commit -F /tmp/cmsg2.txt
set -e
git push -u origin HEAD
gh pr create --base main --head fix/strict-tag-empty-images \
  --title "fix(ci): Contabo dig/preprod roll sync with sources override + fix tag evidence" \
  --body "## Summary
- Container name is correct (\`ghcr.io/am-portfolio/am-api-gateway\`); GHCR package under am-auth is just ownership UI
- Live dig still had old pin \`36312334825\` because AppSet wiped helm.parameters; Sync now includes sources override
- Wait reads \`syncResult.resources[].images\` (summary.images often empty)

## Test plan
- [ ] Re-run Contabo dig Approve
- [ ] Images show new run-id tag
"
PR=$(gh pr list --head fix/strict-tag-empty-images --state open --json number -q '.[0].number')
echo "PR=$PR"
gh pr merge "$PR" --squash --admin --delete-branch || true
sleep 2
git fetch origin main
git log origin/main -1 --oneline
