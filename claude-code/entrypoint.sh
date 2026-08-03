#!/bin/bash
#
# Ubuntu port of the upstream Alpine entrypoint.
# Maps host USER_UID/USER_GID into a 'claude' user, fixes /claude ownership,
# then exec's the command under that user via gosu (the glibc equivalent of
# Alpine's su-exec).

set -e

USER_UID=${USER_UID:-1000}
USER_GID=${USER_GID:-1000}

# Overlay startup hook: <workspace>/.claude-container-overlay/startup.sh runs
# once per container start, just before the command. It exists for per-project
# runtime setup that can't be baked into an image layer because it needs the
# live container — bringing up a daemon, joining a network, seeding a socket.
# (Persistent tooling still belongs in the overlay Dockerfile.)
#
# Run to COMPLETION rather than backgrounded, so an unattended agent starts with
# the setup already done — but under a timeout, since a hook that blocks forever
# would otherwise wedge every launch of that workspace. A failing or timed-out
# hook warns and continues; the session is still usable, just without whatever
# the hook provides.
# CLAUDE_OVERLAY_STARTUP overrides the path, mainly so the hook is testable
# outside a container.
OVERLAY_STARTUP=${CLAUDE_OVERLAY_STARTUP:-/workspace/.claude-container-overlay/startup.sh}
STARTUP_TIMEOUT=${CLAUDE_STARTUP_TIMEOUT:-120}

run_overlay_startup() {
    [ -f "$OVERLAY_STARTUP" ] || return 0
    local runner=() status=0
    if [ "$#" -gt 0 ]; then
        runner=(gosu "$1")
    fi
    echo "Running overlay startup hook: $OVERLAY_STARTUP"
    # Invoked via bash rather than executed directly: the exec bit is easy to
    # lose across a checkout, and failing silently on that would be baffling.
    "${runner[@]}" timeout "$STARTUP_TIMEOUT" bash "$OVERLAY_STARTUP" || status=$?
    if [ "$status" -eq 124 ]; then
        echo "Warning: overlay startup hook timed out after ${STARTUP_TIMEOUT}s (set CLAUDE_STARTUP_TIMEOUT to change)." >&2
    elif [ "$status" -ne 0 ]; then
        echo "Warning: overlay startup hook exited $status; continuing without it." >&2
    fi
    return 0
}

# Root mode: just run as root.
if [ "$USER_UID" -eq 0 ]; then
    run_overlay_startup
    exec "$@"
fi

# Group: reuse if the GID exists, otherwise create 'claude'.
if getent group "$USER_GID" >/dev/null 2>&1; then
    GROUP_NAME=$(getent group "$USER_GID" | cut -d: -f1)
else
    groupadd -g "$USER_GID" claude
    GROUP_NAME=claude
fi

# User: reuse if the UID exists, otherwise create 'claude'.
if getent passwd "$USER_UID" >/dev/null 2>&1; then
    USER_NAME=$(getent passwd "$USER_UID" | cut -d: -f1)
else
    useradd -m -d /home/claude -u "$USER_UID" -g "$USER_GID" -s /bin/bash claude
    USER_NAME=claude
fi

# Make sure the user has a writable HOME for caches like ~/.cache/bazelisk.
USER_HOME=$(getent passwd "$USER_UID" | cut -d: -f6)
if [ -n "$USER_HOME" ] && [ ! -d "$USER_HOME" ]; then
    mkdir -p "$USER_HOME"
    chown "$USER_UID:$USER_GID" "$USER_HOME"
fi

# Same /claude handling as upstream: fix the directory, leave contents alone.
if [ -d /claude ]; then
    chown "$USER_UID:$USER_GID" /claude 2>/dev/null || true
    chmod 755 /claude 2>/dev/null || true
fi

if [ -d /workspace ]; then
    chmod 755 /workspace 2>/dev/null || true
fi

export SHELL=/bin/bash
export HOME="${USER_HOME:-/home/claude}"

# Deploy the skills baked into the image (see Dockerfile / skills/) into Claude's
# skills directory so they're available in every workspace without per-project
# provisioning. Refreshed on every start so they always match the image version.
#
# Deploy ONLY into Claude's actual config dir ($CLAUDE_CONFIG_DIR, normally the
# bind-mounted /claude). Do NOT create $HOME/.claude: when CLAUDE_CONFIG_DIR is
# relocated, a stray ~/.claude makes Claude treat the run as a fresh install and
# re-prompt for bypass-permissions/trust acceptance (the acceptance state lives in
# <config-dir>/.claude.json). We only touch the skills subdir, never the config
# files alongside it.
SKILL_SRC=/opt/claude-container/skills
SKILL_DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
if [ -d "$SKILL_SRC" ]; then
    mkdir -p "$SKILL_DEST"
    cp -a "$SKILL_SRC/." "$SKILL_DEST/"
    chown -R "$USER_UID:$USER_GID" "$SKILL_DEST"
fi

# Named-service mux: tunnels connections on its single port to in-container
# service ports declared in the workspace overlay's overlay.json ("services").
# The launcher publishes the mux port on an ephemeral host port and the host's
# claude-container-router routes to services through it by name. overlay.json is
# re-read per connection, so services declared mid-session need no restart.
# Runs as the mapped user; survives the exec below as a child of PID 1.
if [ -x /usr/local/bin/svc-mux ] && command -v python3 >/dev/null 2>&1; then
    gosu "$USER_NAME" /usr/local/bin/svc-mux >/tmp/svc-mux.log 2>&1 &
fi

# Runs as the mapped user, not root: a hook needing privilege should go through
# sudo, which the overlay Dockerfile has to install and grant deliberately.
run_overlay_startup "$USER_NAME"

exec gosu "$USER_NAME" "$@"
