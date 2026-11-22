#!/usr/bin/env bash
set -euo pipefail
# With GH_TOKEN set, entrypoint.sh should make git authenticate to
# github.com over HTTPS with it, and rewrite SSH-style github.com remotes to
# HTTPS (collie's session Pods only allow 443 egress). Verifies: (1) git's
# credential lookup for github.com returns the token, (2) git@ and ssh://
# github.com URLs resolve to https://, (3) other hosts are left alone,
# (4) without GH_TOKEN none of this is configured.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source test/lib_arch.sh
docker build -t agent-container-test --build-arg TARGETARCH="$TARGETARCH" . > /dev/null

cid=$(docker run -d --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -e GH_TOKEN=test-token-123 agent-container-test idle)
plain=$(docker run -d --rm --cap-add=NET_ADMIN --cap-add=NET_RAW agent-container-test idle)
cleanup() { docker stop "$cid" "$plain" > /dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 2

fail=0

cred=$(docker exec "$cid" gosu appuser sh -c 'printf "protocol=https\nhost=github.com\n\n" | git credential fill')
if echo "$cred" | grep -qx 'password=test-token-123'; then
  echo "PASS: git credential lookup for github.com returns GH_TOKEN"
else
  echo "FAIL: git credential lookup did not return GH_TOKEN"
  fail=1
fi

for url in git@github.com:o/r.git ssh://git@github.com/o/r.git; do
  got=$(docker exec "$cid" gosu appuser git ls-remote --get-url "$url")
  if [ "$got" = "https://github.com/o/r.git" ]; then
    echo "PASS: $url resolves to HTTPS"
  else
    echo "FAIL: $url resolved to $got"
    fail=1
  fi
done

got=$(docker exec "$cid" gosu appuser git ls-remote --get-url git@gitlab.com:o/r.git)
if [ "$got" = "git@gitlab.com:o/r.git" ]; then
  echo "PASS: non-GitHub remotes are left alone"
else
  echo "FAIL: git@gitlab.com:o/r.git resolved to $got"
  fail=1
fi

got=$(docker exec "$plain" gosu appuser git ls-remote --get-url git@github.com:o/r.git)
if [ "$got" = "git@github.com:o/r.git" ]; then
  echo "PASS: without GH_TOKEN, github.com remotes are not rewritten"
else
  echo "FAIL: without GH_TOKEN, git@github.com:o/r.git resolved to $got"
  fail=1
fi

exit $fail
