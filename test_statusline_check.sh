#!/usr/bin/env bash
# Checks statusline.sh renders Claude Code's status line JSON as expected
# (colours stripped), and that the Dockerfile installs it and points
# settings.json's statusLine at it.
set -euo pipefail
cd "$(dirname "$0")"

render() { ./statusline.sh | sed 's/\x1b\[[0-9;]*m//g'; }
expect() {
  local name=$1 want=$2 got=$3
  [ "$got" = "$want" ] || { echo "FAIL: $name"; echo "  want: $want"; echo "   got: $got"; exit 1; }
}

got=$(TZ=UTC render <<'JSON'
{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},
 "context_window":{"context_window_size":200000,"total_input_tokens":84321,"used_percentage":42.2},
 "rate_limits":{"five_hour":{"used_percentage":23.4,"resets_at":"2026-10-25T14:05:00Z"},
                "seven_day":{"used_percentage":81,"resets_at":1793000000}},
 "cost":{"total_cost_usd":1.234}}
JSON
)
expect "full payload" "Opus 5.5 high · ctx 84k/200k 42% · 5h 23% ↻14:05 · 7d 81% ↻$(TZ=UTC date -d @1793000000 '+%a %H:%M') · \$1.23" "$got"

got=$(render <<<'{"model":{"display_name":"Sonnet 5"},"context_window":{"context_window_size":1000000,"total_input_tokens":512,"used_percentage":0}}')
expect "no rate limits, 1M window" "Sonnet 5 · ctx 512/1M 0%" "$got"

got=$(TZ=UTC render <<<'{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1793000000000}}}')
expect "epoch-ms reset" "5h 5% ↻$(TZ=UTC date -d @1793000000 +%H:%M)" "$got"

got=$(render <<<'not json')
expect "garbage input" "" "$got"

grep -q '^COPY statusline.sh /usr/local/bin/claude-statusline$' Dockerfile || { echo "FAIL: statusline.sh not installed"; exit 1; }
grep -q 'chmod 755 .*/usr/local/bin/claude-statusline' Dockerfile || { echo "FAIL: claude-statusline not executable"; exit 1; }
sed -n "s/^RUN echo '\({\"skipDangerousModePermissionPrompt\".*}\)' >.*/\1/p" Dockerfile \
  | jq -e '.statusLine == {"type":"command","command":"/usr/local/bin/claude-statusline"}' >/dev/null \
  || { echo "FAIL: settings.json statusLine not wired to claude-statusline"; exit 1; }

echo "PASS: statusline"
