#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"

MOUNT_DOCKER_SOCKET=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--mount-docker-socket" ]; then
    MOUNT_DOCKER_SOCKET=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]}"

GIT_USER_NAME=$(git config --global user.name 2>/dev/null || echo "")
GIT_USER_EMAIL=$(git config --global user.email 2>/dev/null || echo "")

# The container would otherwise run on UTC, so the status line's rate-limit
# reset time (and every other timestamp) would be off from the host clock.
# Pass the host's zone name: $TZ if set, else read it from the /etc/localtime
# symlink (…/zoneinfo/America/Edmonton on both macOS and Linux).
HOST_TZ="${TZ:-$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')}"

echo "=== Building agent container ==="
docker build -t agent-container "$SCRIPT_DIR"

# The image and its volumes used to be named opencode-sandbox*. Docker can't
# rename a volume, so on the first run after the rename, copy each old volume
# into its new name; otherwise the Claude login and shell history would be
# silently lost. Runs only while the new volume doesn't exist yet. The old
# volume is left in place — remove it by hand once the new one is confirmed
# working. If the copy fails, the half-filled new volume is removed so the
# next run retries instead of skipping.
migrate_volume() {
  local old="$1" new="$2"
  docker volume inspect "$new" >/dev/null 2>&1 && return 0
  docker volume inspect "$old" >/dev/null 2>&1 || return 0
  echo "Migrating Docker volume $old -> $new"
  docker volume create "$new" >/dev/null
  if ! docker run --rm --user root --entrypoint cp \
      -v "$old":/from:ro -v "$new":/to \
      agent-container -a /from/. /to/; then
    docker volume rm "$new" >/dev/null 2>&1 || true
    echo "Failed to migrate $old -> $new; leaving $old untouched" >&2
    exit 1
  fi
}
migrate_volume opencode-sandbox-history agent-container-history
migrate_volume opencode-sandbox-claude-config agent-container-claude-config

echo "=== Running agent container ==="
echo "Workspace: $WORKSPACE_DIR"
# agent-container-claude-config holds the whole ~/.claude dir, but only the
# OAuth credentials in it are actually meant to survive across runs.
# entrypoint.sh re-seeds CLAUDE.md/settings.json/plugins from the image and
# wipes projects/ (memory + session history, which would otherwise bleed
# across different host projects since they all mount to /workspace) on
# every start.
# Persist Google auth token
antigravity_auth_dir="${HOME}/.gemini/antigravity-cli"
mkdir -p "$antigravity_auth_dir"

# One port per run for whatever an agent wants to serve (dev server, preview,
# OAuth callback). Picked at random from the IANA ephemeral range so concurrent
# sandboxes don't collide, skipping anything already listening on the host
# (bash's /dev/tcp, so no lsof/ss dependency across macOS and Linux). Mapped to
# the same number inside the container so the URL an agent prints also works
# from the host. Set PUBLISH_PORT on the host to pin it instead.
pick_publish_port() {
  local port
  for _ in $(seq 50); do
    port=$((49152 + RANDOM % 16384))
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { echo "$port"; return 0; }
  done
  echo "Could not find a free port in 49152-65535" >&2
  return 1
}
PUBLISH_PORT="${PUBLISH_PORT:-$(pick_publish_port)}"
echo "Published port: http://localhost:$PUBLISH_PORT (PUBLISH_PORT in the container)"

DOCKER_SOCKET_ARGS=()
if [ "$MOUNT_DOCKER_SOCKET" = "true" ]; then
  echo "Mounting host Docker socket into the sandbox (--mount-docker-socket)"
  DOCKER_SOCKET_ARGS=(--group-add docker -v /var/run/docker.sock:/var/run/docker.sock)
fi

docker run -it --rm \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:$PUBLISH_PORT:$PUBLISH_PORT" \
  -v "$WORKSPACE_DIR":/workspace \
  -v agent-container-history:/commandhistory \
  -v agent-container-claude-config:/home/appuser/.claude \
  "${DOCKER_SOCKET_ARGS[@]}" \
  -v "$antigravity_auth_dir":/home/appuser/.gemini/antigravity-cli \
  -e NODE_OPTIONS="--max-old-space-size=4096" \
  -e HOME=/home/appuser \
  -e HOST_WORKSPACE="$WORKSPACE_DIR" \
  -e GIT_USER_NAME="$GIT_USER_NAME" \
  -e GIT_USER_EMAIL="$GIT_USER_EMAIL" \
  -e TENSORZERO_BASE_URL="${TENSORZERO_BASE_URL:-}" \
  -e PUBLISH_PORT="$PUBLISH_PORT" \
  ${HOST_TZ:+-e TZ="$HOST_TZ"} \
  -w /workspace \
  agent-container \
  "$@"
