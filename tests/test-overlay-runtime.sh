#!/bin/bash
#
# Tests for the overlay's runtime docker flags (overlay.json "capabilities",
# "devices", "sysctls", "env") and the entrypoint's startup.sh hook.
#
# The launcher runs against a stubbed docker and a stubbed router, so the flags
# it would hand to `docker run` are observable without starting a container.
# The entrypoint is exercised in its root-mode path, which skips the user
# mapping and so needs neither root nor Linux.
#
# Usage: tests/test-overlay-runtime.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"
ENTRYPOINT="$REPO_DIR/claude-code/entrypoint.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (needle '$3' not in output)"; echo "---"; echo "$2" | head -20; echo "---" ;;
    esac
}

assert_not_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) fail "$1 (unwanted '$3' in output)"; echo "---"; echo "$2" | head -20; echo "---" ;;
        *) pass "$1" ;;
    esac
}

# --- stubs --------------------------------------------------------------------

mkdir -p "$TMP/bin"

# Stub docker: echo the run argv so the flags can be asserted on. `image` exits
# non-zero (no cached overlay image) and `run` returns immediately.
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    port) echo "127.0.0.1:45678"; exit 0 ;;
    ps) exit 0 ;;
    run) echo "DOCKER-RUN: $*"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# The launcher looks for the router next to itself, so run a copy out of $TMP
# and put a no-op router beside it — no real daemon starts.
cp "$LAUNCHER" "$TMP/bin/claude-container"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/claude-container-router"
chmod +x "$TMP/bin/claude-container-router"

LAUNCH_HOME="$TMP/home"
mkdir -p "$LAUNCH_HOME"

# run_launcher <workspace> [env assignments...] -> combined output
run_launcher() {
    local ws="$1"; shift
    (cd "$ws" && env HOME="$LAUNCH_HOME" PATH="$TMP/bin:$PATH" "$@" \
        bash "$TMP/bin/claude-container" true 2>&1)
}

new_workspace() { # name -> path, with an overlay dir ready
    local ws="$TMP/$1"
    mkdir -p "$ws/.claude-container-overlay"
    printf '%s\n' "$ws"
}

# --- accepted flags -----------------------------------------------------------

echo "== accepted runtime flags =="

WS="$(new_workspace ws-ok)"
cat > "$WS/.claude-container-overlay/overlay.json" <<'EOF'
{
  "ports": ["8099:8099"],
  "capabilities": ["NET_ADMIN", "cap_sys_ptrace"],
  "devices": ["/dev/net/tun", "/dev/bus/usb:/dev/bus/usb:rwm"],
  "sysctls": {"net.ipv4.ip_forward": 1, "net.ipv6.conf.all.disable_ipv6": "0"},
  "env": ["TS_AUTHKEY", "TS_HOSTNAME=worker-1"]
}
EOF
out="$(run_launcher "$WS" TS_AUTHKEY=tskey-secret-value)"

assert_contains "capability is passed as --cap-add" "$out" "--cap-add NET_ADMIN"
assert_contains "capability is normalized to upper case" "$out" "--cap-add CAP_SYS_PTRACE"
assert_contains "device is passed as --device" "$out" "--device /dev/net/tun"
assert_contains "device permissions are preserved" "$out" "--device /dev/bus/usb:/dev/bus/usb:rwm"
assert_contains "numeric sysctl is stringified" "$out" "--sysctl net.ipv4.ip_forward=1"
assert_contains "string sysctl is passed through" "$out" "--sysctl net.ipv6.conf.all.disable_ipv6=0"
assert_contains "env is forwarded by name" "$out" "-e TS_AUTHKEY"
assert_contains "literal env keeps its value" "$out" "-e TS_HOSTNAME=worker-1"
assert_contains "ports still work alongside runtime flags" "$out" "-p 8099:8099"

# By-name forwarding must not put the secret in the container's argv.
docker_line="$(printf '%s\n' "$out" | grep '^DOCKER-RUN:')"
assert_not_contains "secret value never reaches docker argv" "$docker_line" "tskey-secret-value"
assert_not_contains "summary masks literal env values" \
    "$(printf '%s\n' "$out" | grep 'Overlay runtime flags')" "worker-1"

# --- rejected flags -----------------------------------------------------------

echo "== rejected runtime flags =="

WS="$(new_workspace ws-bad)"
cat > "$WS/.claude-container-overlay/overlay.json" <<'EOF'
{
  "capabilities": ["ALL", "NET ADMIN"],
  "devices": ["/etc/passwd", "/dev/../etc/shadow", "/dev/sda:/dev/sda:xyz"],
  "sysctls": {"kernel.hostname": "evil"},
  "env": ["1BAD", "UNSET_ON_PURPOSE"]
}
EOF
out="$(run_launcher "$WS")"
docker_line="$(printf '%s\n' "$out" | grep '^DOCKER-RUN:')"

assert_not_contains "refuses --cap-add ALL" "$docker_line" "ALL"
assert_contains "explains why ALL was refused" "$out" 'refusing "ALL"'
assert_not_contains "refuses a non-/dev device path" "$docker_line" "/etc/passwd"
assert_not_contains "refuses a device path escaping /dev" "$docker_line" "shadow"
assert_not_contains "refuses malformed device permissions" "$docker_line" "/dev/sda"
assert_not_contains "refuses a host-wide sysctl" "$docker_line" "kernel.hostname"
assert_not_contains "refuses a malformed env name" "$docker_line" "1BAD"
assert_not_contains "skips an env var unset in the environment" "$docker_line" "UNSET_ON_PURPOSE"
assert_contains "warns about the unset env var" "$out" "UNSET_ON_PURPOSE"
# A bad overlay must not take the launch down with it.
assert_contains "still launches despite rejected entries" "$out" "DOCKER-RUN:"

echo "== no runtime keys =="

WS="$(new_workspace ws-empty)"
echo '{"services": {"web": 8080}}' > "$WS/.claude-container-overlay/overlay.json"
out="$(run_launcher "$WS")"
assert_contains "an overlay without runtime keys still launches" "$out" "DOCKER-RUN:"
assert_not_contains "and adds no runtime flags" "$out" "Overlay runtime flags"

# --- image hash ---------------------------------------------------------------

echo "== startup.sh is a runtime input, not a build input =="

WS="$(new_workspace ws-hash)"
echo "RUN true" > "$WS/.claude-container-overlay/Dockerfile"
echo "echo one" > "$WS/.claude-container-overlay/startup.sh"
echo "conf" > "$WS/.claude-container-overlay/extra.conf"

overlay_tag() { printf '%s\n' "$1" | sed -n 's/.*\(claude-container-overlay:[0-9a-f]*\).*/\1/p' | head -1; }

before="$(overlay_tag "$(run_launcher "$WS")")"
echo "echo two — a different hook" > "$WS/.claude-container-overlay/startup.sh"
after="$(overlay_tag "$(run_launcher "$WS")")"
echo "conf changed" > "$WS/.claude-container-overlay/extra.conf"
after_ctx="$(overlay_tag "$(run_launcher "$WS")")"

if [ -n "$before" ]; then
    pass "overlay image is tagged with a hash"
else
    fail "overlay image is tagged with a hash"
fi
if [ "$before" = "$after" ]; then
    pass "editing startup.sh does not trigger a rebuild"
else
    fail "editing startup.sh does not trigger a rebuild (got: '$after', want: '$before')"
fi
if [ "$after_ctx" != "$after" ]; then
    pass "editing a build-context file still does"
else
    fail "editing a build-context file still does (hash unchanged: '$after_ctx')"
fi

# --- startup hook -------------------------------------------------------------

echo "== overlay startup hook =="

# Root mode (USER_UID=0) runs the hook and exec's the command without touching
# the user-mapping path, so this works off-container.
run_entrypoint() { # script-body -> output
    printf '%s\n' "$1" > "$TMP/startup.sh"
    (env PATH="$TMP/bin:$PATH" USER_UID=0 CLAUDE_OVERLAY_STARTUP="$TMP/startup.sh" \
        CLAUDE_STARTUP_TIMEOUT=2 bash "$ENTRYPOINT" echo COMMAND-RAN 2>&1)
}

# macOS has no coreutils `timeout`; stub one that just runs the command.
if ! command -v timeout >/dev/null 2>&1; then
    cat > "$TMP/bin/timeout" <<'EOF'
#!/bin/bash
duration="$1"; shift
"$@" &
pid=$!
( sleep "$duration"; kill -9 "$pid" 2>/dev/null ) &
watchdog=$!
wait "$pid"; status=$?
kill "$watchdog" 2>/dev/null
[ "$status" -ge 128 ] && exit 124
exit "$status"
EOF
    chmod +x "$TMP/bin/timeout"
fi

out="$(run_entrypoint 'echo HOOK-RAN')"
assert_contains "hook runs before the command" "$out" "HOOK-RAN"
assert_contains "command still runs after the hook" "$out" "COMMAND-RAN"

out="$(run_entrypoint 'exit 3')"
assert_contains "a failing hook warns" "$out" "exited 3"
assert_contains "a failing hook does not block the command" "$out" "COMMAND-RAN"

out="$(run_entrypoint 'sleep 30')"
assert_contains "a hanging hook times out" "$out" "timed out"
assert_contains "a timed-out hook does not block the command" "$out" "COMMAND-RAN"

rm -f "$TMP/startup.sh"
out="$(env PATH="$TMP/bin:$PATH" USER_UID=0 CLAUDE_OVERLAY_STARTUP="$TMP/startup.sh" \
    bash "$ENTRYPOINT" echo COMMAND-RAN 2>&1)"
assert_contains "a missing hook is not an error" "$out" "COMMAND-RAN"
assert_not_contains "and is not announced" "$out" "startup hook"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
