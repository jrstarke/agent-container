#!/usr/bin/env bash
set -euo pipefail
# Static check that docker.yml publishes images for same-repo pull requests
# (tagged with the PR head SHA) but never for fork PRs.
cd "$(dirname "${BASH_SOURCE[0]}")"
wf=.github/workflows/docker.yml
fail=0
check() {
  if grep -qF -- "$2" "$wf"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi
}
check "PR images tagged with head SHA, not merge SHA" "DOCKER_METADATA_PR_HEAD_SHA: true"
check "PR builds check out the head commit" "ref: \${{ github.event.pull_request.head.sha || github.sha }}"
check "same-repo PRs push" "github.event.pull_request.head.repo.full_name == github.repository"
if grep -qF "push: \${{ github.event_name != 'pull_request' }}" "$wf"; then
  echo "FAIL: PR builds still never push"; fail=1
else
  echo "PASS: PR builds are not unconditionally build-only"
fi
exit $fail
