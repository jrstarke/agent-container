#!/bin/bash
set -e

if [ "$SKIP_FIREWALL" != "true" ] && [ -f /usr/local/bin/init-firewall.sh ]; then
  /usr/local/bin/init-firewall.sh
fi

# ~/.claude is a named volume that persists across --rm runs, which is only
# actually wanted for one thing: the OAuth credentials in
# ~/.claude/.credentials.json, without which every run would need a fresh
# browser login. Everything else under ~/.claude either drifts from the
# image (CLAUDE.md/settings.json/plugins get silently shadowed by whatever
# the volume captured the first time it was created — a rebuild changes
# nothing at runtime until this fix) or leaks across unrelated host projects
# (memory, session history, file-history/backups of edited files, prompt
# history — all keyed by container path, so every different host project run
# through this sandbox shares one bucket since they all mount to /workspace).
# Allowlist rather than enumerate the leaky parts: anything new Claude Code
# starts writing under ~/.claude in a future version defaults to wiped, not
# silently persisted.
find /home/appuser/.claude -mindepth 1 -maxdepth 1 ! -name .credentials.json -exec rm -rf {} +
cp -r /opt/sandbox-seed/CLAUDE.md /opt/sandbox-seed/settings.json /opt/sandbox-seed/plugins /home/appuser/.claude/
chown -R appuser:appuser /home/appuser/.claude

if [ -n "$GIT_USER_NAME" ] || [ -n "$GIT_USER_EMAIL" ]; then
  gosu appuser git config --global user.name "$GIT_USER_NAME"
  gosu appuser git config --global user.email "$GIT_USER_EMAIL"
fi

# opencode.json.container ships with a placeholder TensorZero baseURL
# (tensorzero.example.com) since the real gateway is host/user-specific and
# shouldn't be baked into the image or committed. Substitute in the real
# value at runtime if the host provided one, so the checked-in file never
# needs to carry it.
if [ -n "${TENSORZERO_BASE_URL:-}" ]; then
  sed -i "s|https://tensorzero.example.com/openai/v1|${TENSORZERO_BASE_URL}|" \
    /home/appuser/.config/opencode/opencode.json
fi

# Files under /workspace arrive through the host bind mount carrying the host
# user's ownership (uid 501 on macOS), but the container runs as appuser
# (uid 1000). Git compares the repo's st_uid against geteuid(), sees a
# mismatch, and refuses every command with "detected dubious ownership".
# Writes themselves work fine — permission enforcement happens host-side — so
# git's heuristic is the only thing actually broken.
#
# The mismatch can't be fixed at the layers above: Colima's mounts (sshfs,
# virtiofs, 9p alike) present the host uid with no remapping knob, and running
# the container as uid 501 would strand the entrypoint, which needs root for
# init-firewall.sh before it drops to appuser. Declaring the mount safe is the
# fix, and it's semantically honest: the check exists to stop you operating on
# *another* user's repo on a shared machine, and /workspace is by construction
# this user's own project in a single-user sandbox.
#
# Both entries are needed: "/workspace/*" covers nested repos (submodules,
# worktrees) but not /workspace itself. unset-all first so the list can't grow
# duplicates if ~/.gitconfig is ever made to persist across runs.
gosu appuser git config --global --unset-all safe.directory || true
gosu appuser git config --global --add safe.directory /workspace
gosu appuser git config --global --add safe.directory '/workspace/*'

case "$1" in
  opencode)
    shift
    exec gosu appuser opencode "$@"
    ;;
  agy)
    shift
    exec gosu appuser agy "$@"
    ;;
  claude)
    shift
    exec gosu appuser claude --dangerously-skip-permissions "$@"
    ;;
  idle)
    # Runs firewall init and every other setup step above, then parks
    # instead of starting an agent — for launchers (e.g. collie's
    # session-pod-launcher) that create a container ahead of time and start
    # the actual agent command later via a separate exec into the already-
    # running container, rather than at container-start time.
    exec sleep infinity
    ;;
  *)
    # Default to opencode when no known tool is specified
    exec gosu appuser opencode "$@"
    ;;
esac
