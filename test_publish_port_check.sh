#!/usr/bin/env bash
# Checks run.sh's per-run published port: a random free port in the IANA
# ephemeral range (49152-65535), published on host loopback only, mapped to the
# same port inside the container, and passed in as PUBLISH_PORT.
set -euo pipefail
cd "$(dirname "$0")"

# Behavioural: pull pick_publish_port out of run.sh and exercise it.
fn=$(sed -n '/^pick_publish_port()/,/^}/p' run.sh)
[ -n "$fn" ] || { echo "FAIL: pick_publish_port not defined in run.sh"; exit 1; }
eval "$fn"
for _ in $(seq 200); do
  p=$(pick_publish_port)
  { [ "$p" -ge 49152 ] && [ "$p" -le 65535 ]; } || { echo "FAIL: port $p outside 49152-65535"; exit 1; }
done

# Static: wired into docker run, loopback-only, same port both sides, env var set.
grep -q 'PUBLISH_PORT="${PUBLISH_PORT:-$(pick_publish_port)}"' run.sh || { echo "FAIL: PUBLISH_PORT not defaulted to pick_publish_port"; exit 1; }
grep -q -- '-p "127.0.0.1:$PUBLISH_PORT:$PUBLISH_PORT"' run.sh || { echo "FAIL: port not published on 127.0.0.1 with matching container port"; exit 1; }
grep -q -- '-e PUBLISH_PORT="$PUBLISH_PORT"' run.sh || { echo "FAIL: PUBLISH_PORT not passed into container"; exit 1; }

echo "PASS: publish port"
