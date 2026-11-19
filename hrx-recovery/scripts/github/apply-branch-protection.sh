#!/usr/bin/env bash
# Requires a GitHub token with Administration: write for this repository.
# Never commit or print GH_TOKEN. This script only protects the specified active branch.
set -euo pipefail
: "${GH_TOKEN:?Set GH_TOKEN in the process environment; never place it in source control}"
OWNER="rongfei611-sys"
REPO="-"
BRANCH="recovery/hrx-20261117"
CHECK_CONTEXT="${HRX_REQUIRED_CHECK_CONTEXT:-HRX Recovery CI / Isolated verification}"
API="https://api.github.com/repos/${OWNER}/${REPO}/branches/${BRANCH}/protection"
BODY="$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["${CHECK_CONTEXT}"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
)"
curl --fail-with-body --silent --show-error \
  -X PUT "${API}" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  --data "${BODY}"
echo
echo "Branch protection request completed. Verify the resulting rule in GitHub Settings/API."
