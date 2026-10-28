#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker build -t agent-container-test --build-arg TARGETARCH=arm64 . > /dev/null
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
