#!/usr/bin/env bash
set -euo pipefail
# Verifies run.sh's hardcoded docker flags cover every entry
# container-contract.json declares required, so the contract (single
# source of truth for what any launcher must supply) and run.sh (the
# hand-maintained local-dev launcher) don't silently drift apart.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

for path in $(jq -r '.mounts.required[].path' container-contract.json); do
  if grep -qF -- "$path" run.sh; then
    echo "PASS: run.sh covers required mount $path"
  else
    echo "FAIL: run.sh missing required mount $path"
    fail=1
  fi
done

for cap in $(jq -r '.capabilities.required[]' container-contract.json); do
  if grep -qF -- "--cap-add=$cap" run.sh; then
    echo "PASS: run.sh covers required capability $cap"
  else
    echo "FAIL: run.sh missing required capability $cap"
    fail=1
  fi
done

exit $fail
