#!/usr/bin/env bash
# Exercises allow-domain.sh against stand-ins: stub dig/ipset on PATH, a temp
# dnsmasq config/pid file, and a fake daemon playing dnsmasq so the
# restart-with-original-arguments path really runs. Also checks the Dockerfile
# installs it and AGENTS.md.container tells agents to use it.
set -euo pipefail
cd "$(dirname "$0")"
repo=$PWD

fail() { echo "FAIL: $*"; exit 1; }
# Zombie-aware: PID 1 here never reaps, so a killed process lingers as a zombie
# that kill -0 still reports. Same check allow-domain.sh uses.
pid_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $s != Z* ]]; }

tmp=$(mktemp -d)
cleanup() { [ -s "$tmp/pid" ] && kill "$(cat "$tmp/pid")" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

mkdir "$tmp/bin"
cat > "$tmp/bin/dig" <<'EOF'
#!/bin/sh
# CNAME line first, like real `dig +short` output for a CDN-backed name.
echo "edge.cdn.example."
echo "203.0.113.7"
echo "203.0.113.8"
EOF
cat > "$tmp/bin/ipset" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/ipset.log"
EOF
# Plays dnsmasq: forks into the background like the real daemon (so the
# helper's restart returns) and writes its pid to --pid-file.
cat > "$tmp/bin/fakedns" <<'EOF'
#!/usr/bin/perl
my ($pidfile) = map { /^--pid-file=(.*)/ ? $1 : () } @ARGV;
exit 0 if fork();
open my $fh, ">", $pidfile or die; print $fh "$$\n"; close $fh;
open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
sleep 1000;
EOF
chmod +x "$tmp/bin/dig" "$tmp/bin/ipset" "$tmp/bin/fakedns"

wait_for_pid_change() {  # $1 = pid to move away from ("" = any pid)
  for _ in $(seq 50); do
    p=$(cat "$tmp/pid" 2>/dev/null || true)
    [ -n "$p" ] && [ "$p" != "$1" ] && { echo "$p"; return 0; }
    sleep 0.1
  done
  return 1
}

printf 'server=192.0.2.1\nipset=/example.com/allowed-domains\n' > "$tmp/conf"
"$tmp/bin/fakedns" --pid-file="$tmp/pid"
old_pid=$(wait_for_pid_change "") || fail "fake dnsmasq didn't start"
orig_cmdline=$(tr '\0' ' ' < "/proc/$old_pid/cmdline")

run() {
  PATH="$tmp/bin:$PATH" ALLOW_DOMAIN_CONF="$tmp/conf" ALLOW_DOMAIN_PIDFILE="$tmp/pid" \
    ALLOW_DOMAIN_ALLOW_NONROOT=1 timeout 20 bash "$repo/allow-domain.sh" "$@"
}

run new.example.org example.com >/dev/null || fail "allow-domain exited non-zero"

grep -qx 'ipset=/new.example.org/allowed-domains' "$tmp/conf" || fail "new domain not added to dnsmasq config"
[ "$(grep -c '^ipset=/example.com/allowed-domains$' "$tmp/conf")" = 1 ] || fail "already-present domain duplicated"
grep -qx 'add allowed-domains 203.0.113.7 -exist' "$tmp/ipset.log" || fail "current IPs not added to ipset"
grep -q 'edge.cdn.example' "$tmp/ipset.log" && fail "CNAME passed to ipset"

pid_alive "$old_pid" && fail "old dnsmasq process not stopped"
new_pid=$(wait_for_pid_change "$old_pid") || fail "dnsmasq not restarted"
pid_alive "$new_pid" || fail "restarted dnsmasq not running"
[ "$(tr '\0' ' ' < "/proc/$new_pid/cmdline")" = "$orig_cmdline" ] || fail "dnsmasq not restarted with its original arguments"

if run 'bad;domain' >/dev/null 2>&1; then fail "invalid domain accepted"; fi
grep -q 'bad;domain' "$tmp/conf" && fail "invalid domain written to config"
if run >/dev/null 2>&1; then fail "no-argument call should fail"; fi

grep -q '^COPY allow-domain.sh /usr/local/bin/allow-domain$' Dockerfile || fail "allow-domain not installed"
grep -q 'chmod 755 .*/usr/local/bin/allow-domain' Dockerfile || fail "allow-domain not executable"
grep -q 'allow-domain' AGENTS.md.container || fail "AGENTS.md.container doesn't mention allow-domain"
grep -q 'ipset add allowed-domains' AGENTS.md.container && fail "AGENTS.md.container still has the raw ipset command"

echo "PASS: allow-domain"
