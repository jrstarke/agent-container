#!/usr/bin/env bash
# Static check: run.sh builds/runs the image and mounts volumes under the
# agent-container name. The old opencode-sandbox names may only appear as the
# source side of a migrate_volume call (or in its explanatory comment).
set -e
cd "$(dirname "$0")"

grep -q 'docker build -t agent-container ' run.sh || { echo "FAIL: image not tagged agent-container"; exit 1; }
grep -q -- '-v agent-container-history:/commandhistory' run.sh || { echo "FAIL: history volume not renamed"; exit 1; }
grep -q -- '-v agent-container-claude-config:/home/appuser/.claude' run.sh || { echo "FAIL: claude-config volume not renamed"; exit 1; }
grep -q '^migrate_volume opencode-sandbox-history agent-container-history$' run.sh || { echo "FAIL: history volume not migrated"; exit 1; }
grep -q '^migrate_volume opencode-sandbox-claude-config agent-container-claude-config$' run.sh || { echo "FAIL: claude-config volume not migrated"; exit 1; }

stray=$(grep -n 'opencode-sandbox' run.sh | grep -v ':migrate_volume opencode-sandbox-' | grep -v ':# ' || true)
[ -z "$stray" ] || { echo "FAIL: stray opencode-sandbox reference(s):"; echo "$stray"; exit 1; }

echo "PASS: agent-container naming"
