# Launch Contract, Config Ownership Fix, zsh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the root-owned `~/.config` bug, add zsh as the default interactive shell, and add a `container-contract.json` declaring what any launcher (docker CLI, Kubernetes) must supply for this image to work — so `run.sh` and a future Kubernetes-based launcher (collie) don't silently drift on that list.

**Architecture:** Three independent, additive changes to the existing single-stage `Dockerfile`, plus one new declarative JSON file and one new bash test script following this repo's existing `test/*.sh` convention (simple PASS/FAIL scripts, not wired into CI — matches `test/claude_smoke_test.sh` and `test_models_dev_check.sh`, neither of which CI currently runs).

**Tech Stack:** Docker (BuildKit), bash, jq (for the contract-coverage test).

**Spec:** `/workspace/collie-container/.worktrees/collie-deployment/docs/superpowers/specs/2026-08-29-collie-agent-split-design.md`, section B.

## Global Constraints

- `TARGETARCH` build arg is required and must be passed explicitly (`Dockerfile:3-4`) — every `docker build` in this plan needs `--build-arg TARGETARCH=arm64` (this sandbox is arm64; confirmed via `uname -m` → `aarch64` / `dpkg --print-architecture` → `arm64`).
- Do not use `docker buildx` — not installed in this sandbox. Plain `docker build` is sufficient for functional verification of these changes; cross-arch correctness is CI's job (`.github/workflows/docker.yml`, `platforms: linux/amd64,linux/arm64`), not this sandbox's.
- Follow existing test convention exactly: standalone bash script, `set -euo pipefail` (or `set -e`), builds the image if needed, `PASS:`/`FAIL:` echo lines, non-zero exit on any failure. Do not wire new tests into `.github/workflows/docker.yml` — that's a separate, unrelated change not requested here.

---

### Task 1: Fix root-owned `~/.config`

**Files:**
- Modify: `Dockerfile:154-156` (insert before the `COPY init-firewall.sh` block)
- Test: `test/config_ownership_test.sh` (new)

**Interfaces:**
- Produces: `/home/appuser/.config` owned `appuser:appuser` at image build time — later tasks (and `collie-container`, which builds `FROM` this image) can rely on this without their own workaround.

- [ ] **Step 1: Write the failing test**

```bash
cat > test/config_ownership_test.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Regression test: /home/appuser/.config used to be created implicitly by a
# plain `COPY ... /home/appuser/.config/opencode/...` with no --chown, which
# Docker creates as root:root regardless of the image's later USER/gosu
# usage. appuser could read existing entries under .config but not create
# new ones (e.g. `gh auth login` failing with
# "mkdir /home/appuser/.config/gh: permission denied").
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker build -t agent-container-test --build-arg TARGETARCH=arm64 . > /dev/null
owner=$(docker run --rm agent-container-test stat -c %U /home/appuser/.config)
if [ "$owner" = "appuser" ]; then
  echo "PASS: /home/appuser/.config is owned by appuser"
  exit 0
else
  echo "FAIL: /home/appuser/.config is owned by $owner, expected appuser"
  exit 1
fi
EOF
chmod +x test/config_ownership_test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/config_ownership_test.sh`
Expected: `FAIL: /home/appuser/.config is owned by root, expected appuser`

- [ ] **Step 3: Fix the Dockerfile**

Insert immediately before line 155 (`COPY init-firewall.sh /usr/local/bin/init-firewall.sh`):

```dockerfile
# /home/appuser/.config used to be created implicitly (root:root) by the
# COPY .../opencode/... lines below, since Docker auto-creates missing COPY
# parent directories as root regardless of any earlier USER/gosu usage.
# Create and chown it explicitly first, the same way .gemini and .claude
# already are above.
RUN mkdir -p /home/appuser/.config && chown appuser:appuser /home/appuser/.config
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/config_ownership_test.sh`
Expected: `PASS: /home/appuser/.config is owned by appuser`

- [ ] **Step 5: Commit**

```bash
git add Dockerfile test/config_ownership_test.sh
git commit -m "$(cat <<'EOF'
fix: create /home/appuser/.config as appuser before it's populated

COPY without --chown creates missing parent directories as root:root
regardless of any earlier USER/gosu usage, so /home/appuser/.config
ended up root-owned once the opencode config COPY lines ran. appuser
could read existing entries but not create new ones under it (e.g.
`gh auth login` failing with "mkdir .../config/gh: permission denied").

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: zsh as appuser's default shell

**Files:**
- Modify: `Dockerfile:8-11` (apt package list), `Dockerfile:38` (`useradd -s`)
- Test: `test/default_shell_test.sh` (new)

**Interfaces:**
- Produces: `appuser`'s login shell is `/usr/bin/zsh`, with `zsh-syntax-highlighting`/completions available on PATH — no other task depends on this, it's a standalone environment change.

- [ ] **Step 1: Write the failing test**

```bash
cat > test/default_shell_test.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker build -t agent-container-test --build-arg TARGETARCH=arm64 . > /dev/null
shell=$(docker run --rm agent-container-test getent passwd appuser | cut -d: -f7)
if [ "$shell" = "/usr/bin/zsh" ]; then
  echo "PASS: appuser's default shell is zsh"
else
  echo "FAIL: appuser's default shell is $shell, expected /usr/bin/zsh"
  exit 1
fi
if docker run --rm agent-container-test test -f /usr/share/zsh/vendor-completions/_docker 2>/dev/null || \
   docker run --rm agent-container-test bash -lc 'zsh -c "autoload -U compinit && compinit" 2>&1' | grep -qv "command not found"; then
  echo "PASS: zsh completion system is available"
else
  echo "FAIL: zsh completion system not available"
  exit 1
fi
EOF
chmod +x test/default_shell_test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/default_shell_test.sh`
Expected: `FAIL: appuser's default shell is /bin/bash, expected /usr/bin/zsh`

- [ ] **Step 3: Install zsh and set it as appuser's shell**

Modify the first `apt-get install` block (`Dockerfile:8-11`) to add `zsh`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git iptables ipset dnsutils coreutils procps jq bash gosu docker-cli iproute2 libatomic1 golang-go openssh-client gh zsh \
  && update-ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
```

Change `Dockerfile:38` from:

```dockerfile
RUN mkdir -p /home/appuser && useradd -m -s /bin/bash appuser || true
```

to:

```dockerfile
RUN mkdir -p /home/appuser && useradd -m -s /usr/bin/zsh appuser || true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/default_shell_test.sh`
Expected: both `PASS:` lines

- [ ] **Step 5: Commit**

```bash
git add Dockerfile test/default_shell_test.sh
git commit -m "$(cat <<'EOF'
feat: make zsh appuser's default shell

collie-container (this image's downstream consumer) is effectively a
terminal multiplexer — its interactive shell use benefits from
completions that plain sh/bash here didn't have. Costs nothing for
the local dev (run.sh) case either.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `container-contract.json`

**Files:**
- Create: `container-contract.json`
- Modify: `Dockerfile` (COPY it into the image)
- Test: `test/contract_coverage_test.sh` (new)

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: `/opt/agent-container/container-contract.json` inside the image (any downstream consumer, e.g. `collie-container`, can read it at a fixed path since `collie-container` is `FROM` this image); `container-contract.json` at the repo root (source of truth `run.sh` and any external launcher, e.g. collie's Pod-builder, is reviewed against).

- [ ] **Step 1: Write the failing test**

```bash
cat > test/contract_coverage_test.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Verifies run.sh's hardcoded docker flags cover every entry
# container-contract.json declares required, so the contract (single
# source of truth for what any launcher must supply) and run.sh (the
# hand-maintained local-dev launcher) don't silently drift apart.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

for path in $(jq -r '.mounts.required[].path' container-contract.json); do
  if grep -qF -- "$path" run.sh; then
    echo "PASS: run.sh covers required mount $path"
  else
    echo "FAIL: run.sh missing required mount $path"
    fail=1
  fi
done

for cap in $(jq -r '.capabilities.required[]' container-contract.json); do
  if grep -qF -- "--cap-add=$cap" run.sh; then
    echo "PASS: run.sh covers required capability $cap"
  else
    echo "FAIL: run.sh missing required capability $cap"
    fail=1
  fi
done

exit $fail
EOF
chmod +x test/contract_coverage_test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/contract_coverage_test.sh`
Expected: FAIL — `container-contract.json: No such file or directory` (jq errors out, non-zero exit)

- [ ] **Step 3: Create `container-contract.json`**

```bash
cat > container-contract.json << 'EOF'
{
  "description": "Launch contract for the agent-container image: what any launcher (docker CLI, Kubernetes, etc.) must or may supply for the image to function correctly. run.sh (this repo, local dev) and any external launcher (e.g. collie's Kubernetes Pod-builder) are reviewed against this list rather than each hand-copying it independently.",
  "env": {
    "required": [],
    "optional": [
      { "name": "GIT_USER_NAME", "purpose": "git config --global user.name, set by entrypoint.sh if present" },
      { "name": "GIT_USER_EMAIL", "purpose": "git config --global user.email, set by entrypoint.sh if present" },
      { "name": "TENSORZERO_BASE_URL", "purpose": "substituted into ~/.config/opencode/opencode.json's baseURL by entrypoint.sh if present" },
      { "name": "SKIP_FIREWALL", "purpose": "set to 'true' to skip init-firewall.sh at container start, e.g. when the launcher already enforces egress policy itself (a Kubernetes NetworkPolicy)" },
      { "name": "HOST_WORKSPACE", "purpose": "informational, defaults to /workspace via the image's own ENV; override only if the launcher mounts /workspace from a host-relative path tools should report" }
    ]
  },
  "mounts": {
    "required": [
      { "path": "/workspace", "readOnly": false, "purpose": "the project directory agent tools operate on" }
    ],
    "optional": [
      { "path": "/home/appuser/.claude", "readOnly": false, "purpose": "persists Claude Code OAuth credentials (~/.claude/.credentials.json) across restarts; without it every run needs a fresh browser login" },
      { "path": "/commandhistory", "readOnly": false, "purpose": "persists shell history across restarts" },
      { "path": "/var/run/docker.sock", "readOnly": false, "purpose": "grants Docker access inside the container (run.sh's --mount-docker-socket); not required for normal operation and widens the container's effective privileges to node/host-root-equivalent — grant deliberately, never by default" }
    ]
  },
  "capabilities": {
    "required": ["NET_ADMIN", "NET_RAW"],
    "purpose": "init-firewall.sh (run at container start unless SKIP_FIREWALL=true) configures iptables/ipset egress rules; without these capabilities it fails to apply them"
  },
  "entrypoint_commands": ["opencode", "agy", "claude", "(no argument defaults to opencode)"]
}
EOF
```

Add to `Dockerfile`, immediately after the `container-contract.json`-independent `COPY opencode.json.container ...` line (i.e. after `Dockerfile:159`, before `RUN chmod 755 ...` on the old numbering):

```dockerfile
RUN mkdir -p /opt/agent-container
COPY container-contract.json /opt/agent-container/container-contract.json
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/contract_coverage_test.sh`
Expected: 3 `PASS:` lines (mount `/workspace`, capability `NET_ADMIN`, capability `NET_RAW`) — `run.sh` already sets `-v "$WORKSPACE_DIR":/workspace`, `--cap-add=NET_ADMIN`, `--cap-add=NET_RAW`, so this should pass without any `run.sh` change.

- [ ] **Step 5: Commit**

```bash
git add container-contract.json Dockerfile test/contract_coverage_test.sh
git commit -m "$(cat <<'EOF'
feat: add container-contract.json declaring the image's launch contract

Documents the env vars, mounts, and capabilities any launcher (docker
CLI, Kubernetes) must or may supply for this image to work correctly,
baked into the image at /opt/agent-container/container-contract.json
so a downstream consumer built FROM this image (collie-container) can
read it at a fixed path. run.sh and any external launcher are now
reviewed against this single list instead of each re-deriving it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage**: covers spec section B items 1-3 (contract file, `.config` fix, zsh) in full. Item "CI check" from the spec's Testing section is deliberately **not** included as a task — existing `test/*.sh` scripts aren't wired into `.github/workflows/docker.yml` today, and adding that wiring is an unrelated scope expansion not requested; flagged for the user to decide separately.
- **Placeholder scan**: none found — every step has literal file content or exact commands.
- **Type/name consistency**: `container-contract.json`'s path (`/opt/agent-container/container-contract.json`) is the one name used everywhere it's referenced (Task 3 step 3, Interfaces block).
