#!/usr/bin/env bash
set -euo pipefail
# The idle entrypoint command is used by launchers (e.g. collie's
# session-pod-launcher) that create the container ahead of time and start
# the actual agent later via a separate exec, rather than at container-start
# time. Verifies: (1) the container stays up instead of exiting, (2)
# init-firewall.sh's setup still ran (idle must not skip it), (3) a command
# can be exec'd into the already-running container afterward.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker build -t agent-container-test --build-arg TARGETARCH=arm64 . > /dev/null

cid=$(docker run -d --rm --cap-add=NET_ADMIN --cap-add=NET_RAW agent-container-test idle)
cleanup() { docker stop "$cid" > /dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 2

if docker ps --filter "id=$cid" --filter "status=running" -q | grep -q .; then
  echo "PASS: idle mode keeps the container running"
else
  echo "FAIL: idle mode container is not running"
  docker logs "$cid" || true
  exit 1
fi

if docker exec "$cid" iptables -L OUTPUT -n | head -1 | grep -q "policy DROP"; then
  echo "PASS: firewall default-deny policy is applied in idle mode"
else
  echo "FAIL: firewall policy not found in idle mode"
  exit 1
fi

if docker exec "$cid" gosu appuser echo "exec works" > /dev/null; then
  echo "PASS: can exec a command into the idle container as appuser"
else
  echo "FAIL: exec into idle container failed"
  exit 1
fi
