#!/usr/bin/env bash
# Static check: the Dockerfile installs Playwright's Chromium system deps at
# build time, pinned, after Node is available, and cleans up apt/npm caches.
set -euo pipefail
cd "$(dirname "$0")"

grep -q '^ARG PLAYWRIGHT_VERSION=[0-9]' Dockerfile || { echo "FAIL: PLAYWRIGHT_VERSION not pinned"; exit 1; }
grep -q 'npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium' Dockerfile || { echo "FAIL: install-deps chromium step missing"; exit 1; }
node_line=$(grep -n 'asdf install nodejs' Dockerfile | cut -d: -f1)
pw_line=$(grep -n 'install-deps chromium' Dockerfile | cut -d: -f1)
[ "$pw_line" -gt "$node_line" ] || { echo "FAIL: install-deps runs before node is installed"; exit 1; }
grep -A1 'install-deps chromium' Dockerfile | grep -q 'rm -rf /var/lib/apt/lists/\* /root/.npm' || { echo "FAIL: apt lists / npm cache not cleaned"; exit 1; }

echo "PASS: playwright chromium deps"
