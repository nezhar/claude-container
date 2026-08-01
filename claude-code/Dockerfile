# Ubuntu-based replacement for nezhar/claude-container, suitable for Bazel/bzlmod
# polyglot builds (Python via rules_python manylinux wheels, TS via aspect_rules_*).
#
# Mirrors the upstream image's behavior:
#   - Claude Code globally installed (claude on PATH)
#   - Entrypoint maps host UID/GID to a 'claude' user via gosu
#   - WORKDIR /workspace, config bind-mounted at /claude
#
# Adds the toolchain the upstream Alpine image is missing for Bazel:
#   - glibc base (ubuntu:24.04)
#   - bazelisk (drives Bazel per .bazelversion)
#   - build-essential, git, curl, zip/unzip, ca-certificates
#   - Node 22 + pnpm
ARG NODE_VERSION=22.23.0
ARG CLAUDE_CODE_VERSION=2.1.181
ARG PNPM_VERSION=11.8.0
ARG BAZELISK_VERSION=v1.22.1

FROM ubuntu:24.04

ARG NODE_VERSION
ARG CLAUDE_CODE_VERSION
ARG PNPM_VERSION
ARG BAZELISK_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_VERSION=${NODE_VERSION}

# ubuntu:24.04 ships with a default 'ubuntu' user at uid 1000 — remove it so
# the entrypoint can freely allocate uid 1000 (the common host uid) to 'claude'.
RUN userdel -r ubuntu 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gosu \
        zip \
        unzip \
        xz-utils \
        tmux \
        build-essential \
        python3 \
        python3-distutils-extra \
    && rm -rf /var/lib/apt/lists/*

# Node.js — pin to the same version as upstream image. NodeSource doesn't ship
# arbitrary patch releases, so install from the official tarball.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64)  nodearch=x64 ;; \
        arm64)  nodearch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${nodearch}.tar.xz"; \
    tar -xJf "node-v${NODE_VERSION}-linux-${nodearch}.tar.xz" -C /usr/local --strip-components=1 \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md; \
    rm "node-v${NODE_VERSION}-linux-${nodearch}.tar.xz"; \
    node --version; \
    npm --version

# pnpm — install globally via npm so it's baked in (avoids corepack's runtime
# download on first invocation, which would otherwise hit the network when the
# user runs pnpm inside a fresh container).
RUN npm install -g "pnpm@${PNPM_VERSION}" && pnpm --version

# Bazelisk drives Bazel per .bazelversion in the workspace.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL -o /usr/local/bin/bazelisk \
        "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${arch}"; \
    chmod +x /usr/local/bin/bazelisk; \
    ln -s /usr/local/bin/bazelisk /usr/local/bin/bazel

# Claude Code itself.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# claude-tmux: wrapper that launches Claude inside a named tmux session (used by
# `claude-container --tmux`).
COPY claude-tmux /usr/local/bin/claude-tmux
RUN chmod +x /usr/local/bin/claude-tmux

# Bundled Claude Code skills. Baked into the image here; the entrypoint deploys
# them into the user's skills directory at startup so they're available in every
# workspace without per-project provisioning.
COPY skills/ /opt/claude-container/skills/

# UTF-8 locale (glibc's built-in C.utf8) — without it tmux assumes a non-UTF-8
# terminal and renders all non-ASCII output as underscores. Kept last so the
# layer cache above is unaffected.
ENV LANG=C.UTF-8

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sh", "-c", "echo 'Claude Code container is ready!'"]
