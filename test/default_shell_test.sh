#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source test/lib_arch.sh
docker build -t agent-container-test --build-arg TARGETARCH="$TARGETARCH" . > /dev/null
shell=$(docker run --rm --entrypoint getent agent-container-test passwd appuser | cut -d: -f7)
if [ "$shell" = "/usr/bin/zsh" ]; then
  echo "PASS: appuser's default shell is zsh"
else
  echo "FAIL: appuser's default shell is $shell, expected /usr/bin/zsh"
  exit 1
fi
if docker run --rm --entrypoint zsh agent-container-test -c 'autoload -U compinit && compinit' 2>&1; then
  echo "PASS: zsh completion system loads"
else
  echo "FAIL: zsh completion system failed to load"
  exit 1
fi
# An interactive shell must start straight to a prompt: with no ~/.zshrc,
# zsh shows its first-run configuration menu instead (and waits on stdin).
out=$(docker run --rm --entrypoint gosu agent-container-test appuser zsh -ic 'echo "HISTFILE=$HISTFILE"; bindkey "^[[A"' < /dev/null 2>&1)
if echo "$out" | grep -qi 'new user'; then
  echo "FAIL: interactive zsh shows the new-user menu"
  echo "$out"
  exit 1
fi
if echo "$out" | grep -q 'HISTFILE=/commandhistory/.zsh_history' && echo "$out" | grep -q 'up-line-or-beginning-search'; then
  echo "PASS: ~/.zshrc sets history and up-arrow history search"
else
  echo "FAIL: ~/.zshrc history/keybinding not in effect"
  echo "$out"
  exit 1
fi
# dtach holds a session's terminal so a dropped exec connection can reattach
# (collie's session-pod-launcher runs claude under `dtach -A`).
if docker run --rm --entrypoint sh agent-container-test -c 'command -v dtach' > /dev/null; then
  echo "PASS: dtach is installed"
else
  echo "FAIL: dtach is not installed"
  exit 1
fi
