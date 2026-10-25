#!/usr/bin/env bash
# Claude Code status line: model, context window use, plan rate limits, cost.
#   Opus 5.5 high · ctx 84k/200k 42% · 5h 23% ↻14:05 · 7d 61% ↻Thu 10:00 · $1.23
# Reads the status line JSON Claude Code sends on stdin. Percentages turn
# yellow at 50% and red at 80%. rate_limits only exists on a Claude
# subscription once the limits are known, so those segments are simply
# omitted otherwise. cost is Claude Code's API-price estimate for the
# session, not a bill (on a subscription it's a rough gauge of usage).
set -u

input=$(cat)
j() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' DIM=$'\e[2m' RESET=$'\e[0m'

# Colour a percentage by threshold; prints it rounded to a whole number.
pct() {
  local p=${1%.*} c=$GREEN
  [ -z "$p" ] && return
  [ "$p" -ge 50 ] && c=$YELLOW
  [ "$p" -ge 80 ] && c=$RED
  printf '%s%s%%%s' "$c" "$p" "$RESET"
}

# 84000 -> 84k, 1000000 -> 1M
human() {
  local n=${1%.*}
  if [ "$n" -ge 1000000 ]; then
    awk -v n="$n" 'BEGIN { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); print s "M" }'
  elif [ "$n" -ge 1000 ]; then
    printf '%dk' $(( (n + 500) / 1000 ))
  else
    printf '%d' "$n"
  fi
}

# resets_at in local time using date format $2; accepts epoch seconds, epoch ms
# or an ISO string.
reset_time() {
  local r=$1 fmt=$2 secs
  if [[ $r =~ ^[0-9]+$ ]]; then
    secs=$r
    [ "$secs" -gt 100000000000 ] && secs=$(( secs / 1000 ))
    date -d "@$secs" "+$fmt" 2>/dev/null
  else
    date -d "$r" "+$fmt" 2>/dev/null
  fi
}

parts=()

model=$(j '.model.display_name')
effort=$(j '.effort.level')
[ -n "$model" ] && parts+=("${model}${effort:+ ${DIM}${effort}${RESET}}")

size=$(j '.context_window.context_window_size')
used=$(j '.context_window.total_input_tokens')
used_pct=$(j '.context_window.used_percentage')
if [ -n "$size" ] && [ -n "$used" ]; then
  parts+=("ctx $(human "$used")/$(human "$size") $(pct "${used_pct:-0}")")
fi

for win in five_hour:5h seven_day:7d; do
  key=${win%%:*} label=${win##*:}
  p=$(j ".rate_limits.$key.used_percentage")
  [ -z "$p" ] && continue
  seg="$label $(pct "$p")"
  r=$(j ".rate_limits.$key.resets_at")
  # The 5h window resets within the day, so the time is enough; the 7d one
  # needs the weekday too.
  fmt=%H:%M
  [ "$key" = seven_day ] && fmt="%a %H:%M"
  if [ -n "$r" ]; then
    t=$(reset_time "$r" "$fmt")
    [ -n "$t" ] && seg+=" ${DIM}↻${t}${RESET}"
  fi
  parts+=("$seg")
done

cost=$(j '.cost.total_cost_usd')
[ -n "$cost" ] && parts+=("$(printf '$%.2f' "$cost")")

out=""
for p in "${parts[@]}"; do
  out+="${out:+ ${DIM}·${RESET} }$p"
done
printf '%s\n' "$out"
