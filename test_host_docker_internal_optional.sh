#!/usr/bin/env bash
set -euo pipefail
# Test that init-firewall.sh survives host.docker.internal not resolving (k8s
# Pods, or docker run without --add-host): getent exits 2 for an unknown name,
# which under the script's own `set -euo pipefail` would abort it.
cd "$(dirname "${BASH_SOURCE[0]}")"
line=$(grep -m1 '^HOST_DOCKER_INTERNAL_IP=' init-firewall.sh)
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
printf '#!/bin/sh\nexit 2\n' > "$stub/getent"
chmod +x "$stub/getent"
if PATH="$stub:$PATH" bash -c "set -euo pipefail; $line; [ -z \"\$HOST_DOCKER_INTERNAL_IP\" ]"; then
  echo "PASS: unresolvable host.docker.internal is tolerated"
  exit 0
else
  echo "FAIL: unresolvable host.docker.internal aborts init-firewall.sh"
  exit 1
fi
