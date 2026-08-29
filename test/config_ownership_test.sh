#!/usr/bin/env bash
set -euo pipefail
# Regression test: /home/appuser/.config used to be created implicitly by a
# plain `COPY ... /home/appuser/.config/opencode/...` with no --chown, which
# Docker creates as root:root regardless of the image's later USER/gosu
# usage. appuser could read existing entries under .config but not create
# new ones (e.g. `gh auth login` failing with
# "mkdir /home/appuser/.config/gh: permission denied").
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker build -t agent-container-test --build-arg TARGETARCH=arm64 . > /dev/null
# --entrypoint overrides the image's entrypoint.sh, which otherwise treats
# any unrecognized argv as arguments to `opencode` itself (its case
# statement's default branch), not as a shell command to run.
owner=$(docker run --rm --entrypoint stat agent-container-test -c %U /home/appuser/.config)
if [ "$owner" = "appuser" ]; then
  echo "PASS: /home/appuser/.config is owned by appuser"
  exit 0
else
  echo "FAIL: /home/appuser/.config is owned by $owner, expected appuser"
  exit 1
fi
