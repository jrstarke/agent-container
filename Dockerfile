FROM debian:stable-slim

ARG TARGETARCH
RUN : "${TARGETARCH:?TARGETARCH must be set explicitly (e.g. --build-arg TARGETARCH=arm64 or amd64) — the legacy Docker builder does not populate it automatically}"
ARG OPENCODE_VERSION=1.17.13
ARG ASDF_VERSION=0.19.0

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git iptables ipset dnsutils coreutils procps jq bash gosu docker-cli iproute2 libatomic1 golang-go openssh-client gh zsh \
  && update-ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Build dependencies for asdf's python plugin (pyenv/python-build compiles
# CPython from source; there's no prebuilt-binary path like nodejs has).
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
  libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(echo "$TARGETARCH" | sed 's/amd64/x64/;s/arm64/arm64/') && \
  curl -L "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz" -o /tmp/opencode.tar.gz && \
  tar -xzf /tmp/opencode.tar.gz -C /usr/local/bin opencode && \
   chmod +x /usr/local/bin/opencode && \
    # Install Antigravity CLI (latest GitHub release)
    ARCH=$(echo "$TARGETARCH" | sed 's/amd64/x64/;s/arm64/arm64/') && \
      # Download appropriate Antigravity CLI archive based on architecture
      AGY_ASSET="agy_cli_linux_${ARCH}.tar.gz" && \
      curl -L "https://github.com/google-antigravity/antigravity-cli/releases/download/1.1.4/${AGY_ASSET}" -o /tmp/agy.tar.gz && \
      tar -xzf /tmp/agy.tar.gz -C /usr/local/bin antigravity && \
      mv /usr/local/bin/antigravity /usr/local/bin/agy && \
      chmod +x /usr/local/bin/agy && \
       rm /tmp/agy.tar.gz && rm /tmp/opencode.tar.gz

# Install qemu for non-native binaries
RUN apt-get update && apt-get install -y --no-install-recommends qemu-user-static && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/appuser && useradd -m -s /usr/bin/zsh appuser || true
RUN chown -R appuser:appuser /home/appuser
RUN groupadd -g 991 docker || true
RUN usermod -aG docker appuser || true

# Install Claude Code CLI via official installer, as appuser, so it lands under
# /home/appuser/.local/bin and the install-method bookkeeping `claude doctor` checks
# for matches the user the entrypoint actually runs claude as.
RUN gosu appuser bash -lc "curl -fsSL https://claude.ai/install.sh | bash"

RUN ARCH=$(echo "$TARGETARCH" | sed 's/amd64/amd64/;s/arm64/arm64/') && \
  curl -L "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VERSION}/asdf-v${ASDF_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/asdf.tar.gz && \
  tar -xzf /tmp/asdf.tar.gz -C /tmp && \
  mv /tmp/asdf /usr/local/bin/asdf && \
  chmod +x /usr/local/bin/asdf && \
  rm /tmp/asdf.tar.gz

RUN mkdir /commandhistory && touch /commandhistory/.bash_history && chown -R appuser /commandhistory || true

RUN mkdir -p /home/appuser/.asdf/shims && chown -R appuser:appuser /home/appuser/.asdf
RUN mkdir -p /home/appuser/.gemini/config && chown -R appuser:appuser /home/appuser/.gemini
RUN mkdir -p /home/appuser/.claude/config && chown -R appuser:appuser /home/appuser/.claude

# Pre-install node (latest LTS) and python (latest stable 3.x) via asdf, and
# pin them as appuser's global default via `asdf set --home` (writes
# ~/.tool-versions). Versions resolved at the time this was written:
#   node   -> `asdf latest nodejs lts`
#   python -> newest non-experimental 3.x from `asdf list all python`
ARG NODE_VERSION=24.18.0
ARG PYTHON_VERSION=3.14.6
RUN gosu appuser bash -lc "\
  export PATH=/usr/local/bin:\$PATH && \
  asdf plugin add nodejs && \
  asdf plugin add python && \
  asdf install nodejs ${NODE_VERSION} && \
  asdf install python ${PYTHON_VERSION} && \
  asdf set --home nodejs ${NODE_VERSION} && \
  asdf set --home python ${PYTHON_VERSION} \
"

# Install OpenWolf (context-management middleware for coding agents,
# https://github.com/cytostack/openwolf) globally into appuser's asdf-managed
# node, so `openwolf` is on PATH via the asdf shims already on PATH (below).
#
# Pinned, and deliberately NOT on `latest`: earlier 2.x releases (2.0.1) had
# bugs we hit in practice, so this held at the last 1.x release until 2.4.1,
# which is known good. Bare `npm install -g openwolf` would silently move
# this on every rebuild.
ARG OPENWOLF_VERSION=2.4.1
RUN gosu appuser bash -lc "\
  export PATH=/home/appuser/.asdf/shims:\$PATH && \
  npm install -g openwolf@${OPENWOLF_VERSION} \
"

# Seed directory for ~/.claude state that must always reflect the image,
# not whatever a previous container run's named volume happened to capture.
# ~/.claude itself is a named volume (see run.sh) so it survives across
# `--rm` runs for things that should persist, like OAuth credentials — but
# that means anything baked in under ~/.claude at build time is only ever
# seen once, the first time the volume is created, and silently shadowed by
# the volume's own copy on every rebuild after that. entrypoint.sh copies
# CLAUDE.md/settings.json/plugins out of here into ~/.claude on every start
# so those specific pieces stay image-authoritative instead of drifting.
RUN mkdir -p /opt/sandbox-seed && chown appuser:appuser /opt/sandbox-seed

# Pre-accept onboarding and the /workspace trust dialog. ~/.claude.json (note:
# NOT under ~/.claude/ — it's a sibling file) is never mounted, so it's
# already fresh from the image on every run; without this the first-run
# wizard and trust prompt would reappear every time. hasCompletedOnboarding /
# hasTrustDialogAccepted are undocumented internal state keys, not a public
# config surface, but stable enough to rely on given the binary is pinned
# above via DISABLE_UPDATES.
RUN echo '{"hasCompletedOnboarding": true, "projects": {"/workspace": {"hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 1}}}' > /home/appuser/.claude.json && \
  chown appuser:appuser /home/appuser/.claude.json

# Best-effort attempt to skip the Bypass Permissions mode confirmation dialog
# too (untested against a real top-level session; needs verification).
# advisorModel is here because it was previously set at runtime and persisted
# only by accident of the old whole-directory volume mount; baking it in
# keeps that default now that settings.json is re-seeded every start.
# Written to the real ~/.claude/settings.json (not the seed dir) because
# `claude plugin install` below records enabledPlugins into this same file —
# writing straight to the seed copy first would just get overwritten by that
# install with a copy that's missing our manual keys. The seed dir gets the
# post-install merged version instead, see below.
RUN echo '{"skipDangerousModePermissionPrompt": true, "theme": "light", "advisorModel": "opus"}' > /home/appuser/.claude/settings.json && \
  chown appuser:appuser /home/appuser/.claude/settings.json

# Install the Superpowers plugin for Claude Code, mirroring the opencode.json
# declarative "plugin" entry. Docs describe a CLAUDE_CODE_PLUGIN_SEED_DIR /
# CLAUDE_CODE_PLUGIN_CACHE_DIR container-seeding mechanism for this, but it
# did not actually get picked up at runtime when tested against this image
# (v2.1.220) — `claude plugin list` came back empty despite a correctly
# populated seed dir. Installing straight into the default ~/.claude/plugins
# location at build time works and is verified to persist and load normally.
# `claude plugin install` also writes enabledPlugins into settings.json, so
# both plugins/ and settings.json are copied out to the seed dir afterward —
# copying only plugins/ would silently drop the enablement state and the
# plugin would install but never load. Seeding from here (not settings.json
# baked earlier in isolation) is what keeps a rebuild's plugin state actually
# taking effect at runtime instead of being shadowed by whatever an older
# image installed into the volume.
RUN gosu appuser bash -lc "\
  export PATH=/home/appuser/.local/bin:\$PATH && \
  claude plugin marketplace add obra/superpowers-marketplace && \
  claude plugin install superpowers@superpowers-marketplace && \
  cp -r /home/appuser/.claude/plugins /opt/sandbox-seed/plugins && \
  cp /home/appuser/.claude/settings.json /opt/sandbox-seed/settings.json \
"

ENV HOST_WORKSPACE=/workspace
ENV PATH=/home/appuser/.local/bin:/home/appuser/.asdf/shims:$PATH
# Claude Code is distributed via this image, not its own updater; block all
# update paths (background auto-update and manual `claude update`/`install`)
# so the binary installed at build time stays immutable at runtime.
ENV DISABLE_UPDATES=1

# /home/appuser/.config used to be created implicitly (root:root) by the
# COPY .../opencode/... lines below, since Docker auto-creates missing COPY
# parent directories as root regardless of any earlier USER/gosu usage.
# Create and chown it explicitly first, the same way .gemini and .claude
# already are above.
RUN mkdir -p /home/appuser/.config && chown appuser:appuser /home/appuser/.config

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY AGENTS.md.container /home/appuser/.config/opencode/AGENTS.md
COPY AGENTS.md.container /opt/sandbox-seed/CLAUDE.md
COPY opencode.json.container /home/appuser/.config/opencode/opencode.json
RUN mkdir -p /opt/agent-container
COPY container-contract.json /opt/agent-container/container-contract.json
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh
RUN chown appuser:appuser /opt/sandbox-seed/CLAUDE.md

RUN mkdir -p /workspace && chown -R appuser /workspace /commandhistory

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]