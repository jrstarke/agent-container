#!/usr/bin/env bash
set -euo pipefail
# Test that init-firewall.sh DEFAULT_DOMAINS includes models.dev
cd "$(dirname "${BASH_SOURCE[0]}")"
if grep -q "models.dev" init-firewall.sh; then
  echo "PASS: models.dev present"
  exit 0
else
  echo "FAIL: models.dev missing"
  exit 1
fi
