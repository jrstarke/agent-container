#!/usr/bin/env bash
set -euo pipefail
# Test that init-firewall.sh sets up dnsmasq to keep the allowed-domains
# ipset in sync automatically, instead of relying solely on the one-shot
# resolution at container start (which goes stale as soon as an allowed
# domain's IPs rotate).

fail=0

check() {
  local desc="$1" pattern="$2"
  if grep -qE "$pattern" /workspace/init-firewall.sh; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    fail=1
  fi
}

check "generates a per-domain ipset directive for dnsmasq" 'ipset=/\$domain/allowed-domains'
check "captures the upstream resolver before overriding resolv.conf" 'nameserver'
check "launches dnsmasq against the generated conf file" '\-\-conf-file=/etc/dnsmasq\.d/allowed-domains\.conf'
check "dnsmasq is restricted to loopback (avoids clashing with Docker's embedded DNS)" '\-\-listen-address=127\.0\.0\.1'
check "dnsmasq uses an explicit pid file (Debian's default dir is never created here)" '\-\-pid-file='
check "points resolv.conf at dnsmasq" '127\.0\.0\.1'
check "runs a watchdog that restarts dnsmasq if it dies" 'pgrep -x dnsmasq'

if ! grep -q "dnsmasq" /workspace/Dockerfile; then
  echo "FAIL: Dockerfile installs dnsmasq"
  fail=1
else
  echo "PASS: Dockerfile installs dnsmasq"
fi

exit $fail
