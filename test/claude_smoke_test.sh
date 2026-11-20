#!/usr/bin/env bash
set -e
# Build image first if not built
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source test/lib_arch.sh
docker build -t claude-test --build-arg TARGETARCH="$TARGETARCH" .
# Run claude help to verify binary works. Skip the firewall: it needs
# --cap-add=NET_ADMIN, and without it init-firewall.sh (set -e) aborts the
# entrypoint before claude ever runs.
docker run --rm -e SKIP_FIREWALL=true claude-test claude --help > /dev/null
