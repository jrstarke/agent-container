#!/bin/bash
# allow-domain DOMAIN... — allow extra domains through the firewall for the
# rest of this container's life. Run as root from the host:
#   docker exec --user root <container-id> allow-domain example.com
#
# For each domain: adds an ipset= line to dnsmasq's config (so IPs the domain
# rotates to later are allowed when it's looked up — see init-firewall.sh)
# and adds its current IPs to the ipset straight away. dnsmasq only reads
# ipset= lines at startup, so it's then restarted, reusing the exact arguments
# the running process was started with so they can't drift from
# init-firewall.sh. Persistent changes belong in /workspace/allowed-domains.
#
# ALLOW_DOMAIN_CONF / ALLOW_DOMAIN_PIDFILE / ALLOW_DOMAIN_ALLOW_NONROOT exist
# for test_allow_domain.sh.
set -euo pipefail

CONF=${ALLOW_DOMAIN_CONF:-/etc/dnsmasq.d/allowed-domains.conf}
PIDFILE=${ALLOW_DOMAIN_PIDFILE:-/run/dnsmasq-allowed-domains.pid}

if [ "$(id -u)" != 0 ] && [ "${ALLOW_DOMAIN_ALLOW_NONROOT:-}" != 1 ]; then
  echo "allow-domain must run as root: docker exec --user root <container-id> allow-domain DOMAIN..." >&2
  exit 1
fi
[ $# -ge 1 ] || { echo "usage: allow-domain DOMAIN..." >&2; exit 2; }

# Validate everything before changing anything; the name goes into dnsmasq's
# config file, so nothing but hostname characters.
for d in "$@"; do
  [[ $d =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "allow-domain: invalid domain: $d" >&2; exit 2; }
done

for d in "$@"; do
  line="ipset=/$d/allowed-domains"
  grep -qxF "$line" "$CONF" || echo "$line" >> "$CONF"
  # dig +short also prints CNAME targets; keep only IPv4 addresses.
  for ip in $(dig +short A "$d" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true); do
    ipset add allowed-domains "$ip" -exist
  done
done

# Liveness checks ignore zombies: dnsmasq daemonizes, so its parent is PID 1,
# which in this container is claude/opencode and never reaps children. A dead
# dnsmasq stays a zombie that kill -0 and pgrep still report as present.
pid_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $s != Z* ]]; }
name_running() { ps -C "$1" -o stat= 2>/dev/null | grep -qv '^Z'; }

pid=$(cat "$PIDFILE" 2>/dev/null || true)
if [ -z "$pid" ] || ! pid_alive "$pid"; then
  echo "allow-domain: dnsmasq isn't running; current IPs were added, but rotation won't be tracked until it restarts" >&2
  exit 0
fi
mapfile -d '' args < "/proc/$pid/cmdline"
name=$(cat "/proc/$pid/comm")
kill "$pid"
while pid_alive "$pid"; do sleep 0.1; done
# init-firewall.sh's watchdog may have relaunched it in the meantime (it reads
# the same config file), so only start it if nothing is running.
name_running "$name" || "${args[@]}" || name_running "$name"

echo "Allowed until the container restarts: $*"
