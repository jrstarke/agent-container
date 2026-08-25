#!/bin/bash
set -euo pipefail

SKIP_FIREWALL="${SKIP_FIREWALL:-false}"
if [ "$SKIP_FIREWALL" = "true" ]; then
    echo "Skipping firewall (SKIP_FIREWALL=true)"
    exec "$@"
fi

IFS=$'\n\t'

DEFAULT_DOMAINS="
registry.npmjs.org
api.anthropic.com
opencode.ai
sentry.io
mcp.context7.com
mcp.exa.ai
nodejs.org
daily-cloudcode-pa.googleapis.com
oauth2.googleapis.com
www.googleapis.com
lh3.googleusercontent.com
models.dev
"

DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

echo "Adding localhost and Docker networks..."
ipset add allowed-domains 127.0.0.1 -exist

echo "Fetching GitHub IP ranges..."
set -x
gh_ranges=$(curl -s https://api.github.com/meta)
set +x
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

echo "$gh_ranges" | jq -e '.web' >/dev/null 2>&1 || echo "Warning: .web field issue"

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Skipping invalid CIDR: $cidr"
        continue
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '.web + .api + .git | unique | .[]')

ALL_DOMAINS=""

collect_domains() {
    grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*#' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

echo "Starting with default domains:"
echo "$DEFAULT_DOMAINS"
ALL_DOMAINS="$DEFAULT_DOMAINS"

echo "Checking for project domains file: /workspace/allowed-domains"
if [ -f "/workspace/allowed-domains" ]; then
    echo "Reading project allowed domains from /workspace/allowed-domains"
    PROJECT_DOMAINS=$(cat /workspace/allowed-domains | collect_domains)
    echo "Project domains read: $PROJECT_DOMAINS"
    if [ -n "$PROJECT_DOMAINS" ]; then
        ALL_DOMAINS="$ALL_DOMAINS
$PROJECT_DOMAINS"
    fi
fi

# allowed-domains.local is gitignored, for host/user-specific domains (e.g. a
# private API gateway) that shouldn't be committed alongside the shared
# allowed-domains file.
echo "Checking for local domains file: /workspace/allowed-domains.local"
if [ -f "/workspace/allowed-domains.local" ]; then
    echo "Reading local allowed domains from /workspace/allowed-domains.local"
    LOCAL_DOMAINS=$(cat /workspace/allowed-domains.local | collect_domains)
    echo "Local domains read: $LOCAL_DOMAINS"
    if [ -n "$LOCAL_DOMAINS" ]; then
        ALL_DOMAINS="$ALL_DOMAINS
$LOCAL_DOMAINS"
    fi
fi

if [ -n "$ALL_DOMAINS" ]; then
    DOMAINS=$(echo "$ALL_DOMAINS" | sort -u)
else
    echo "Using default allowed domains"
    DOMAINS=$DEFAULT_DOMAINS
fi

for domain in $DOMAINS; do
    domain=$(echo "$domain" | tr -d '[:space:]')
    [ -z "$domain" ] && continue
    
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
    
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" -exist
    done < <(echo "$ips")
done

HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# host.docker.internal (added via `docker run --add-host=host.docker.internal:host-gateway`)
# can resolve to an address outside the container's own default-route subnet
# above -- e.g. when Docker routes host access through a VM layer, as Docker
# Desktop does on Mac/Windows. Allow it explicitly via /etc/hosts rather than
# assuming HOST_NETWORK already covers it.
HOST_DOCKER_INTERNAL_IP=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "$HOST_DOCKER_INTERNAL_IP" ]; then
    echo "Adding host.docker.internal ($HOST_DOCKER_INTERNAL_IP) to allowed domains..."
    ipset add allowed-domains "$HOST_DOCKER_INTERNAL_IP" -exist
fi

echo "Capturing upstream DNS resolver for dnsmasq..."
UPSTREAM_DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -z "$UPSTREAM_DNS" ]; then
    echo "ERROR: Failed to detect upstream DNS resolver"
    exit 1
fi
echo "Upstream DNS resolver: $UPSTREAM_DNS"

# Resolving each allowed domain once above (via dig) only captures a
# snapshot of its current IPs. Services behind CDNs rotate IPs over time,
# which would silently break egress for them mid-session. dnsmasq is set up
# here as the container's resolver so that every time an allowed domain is
# actually queried, its freshly-resolved IPs get added to the same ipset --
# keeping enforcement in sync with DNS reality for the life of the container,
# without re-running this script.
echo "Generating dnsmasq config..."
mkdir -p /etc/dnsmasq.d
{
    echo "server=$UPSTREAM_DNS"
    for domain in $DOMAINS; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        [ -z "$domain" ] && continue
        echo "ipset=/$domain/allowed-domains"
    done
} > /etc/dnsmasq.d/allowed-domains.conf

DNSMASQ_ARGS=(--conf-file=/etc/dnsmasq.d/allowed-domains.conf --listen-address=127.0.0.1 --bind-interfaces --pid-file=/run/dnsmasq-allowed-domains.pid)

echo "Starting dnsmasq..."
mkdir -p /run
dnsmasq "${DNSMASQ_ARGS[@]}"
if ! pgrep -x dnsmasq >/dev/null; then
    echo "ERROR: dnsmasq failed to start"
    exit 1
fi

echo "Starting dnsmasq watchdog..."
(
    while true; do
        sleep 30
        pgrep -x dnsmasq >/dev/null || dnsmasq "${DNSMASQ_ARGS[@]}" || true
    done
) &
disown

echo "Pointing resolv.conf at dnsmasq..."
echo "nameserver 127.0.0.1" > /etc/resolv.conf

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi