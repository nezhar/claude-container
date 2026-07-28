#!/bin/bash
#
# End-to-end tests for named-service forwarding: the in-container svc-mux and
# the host-side claude-container-router, wired together WITHOUT docker — the
# mux runs locally against a fake workspace overlay.json, and a fake registry
# entry points the router at it. Exercises host-form routing, the zero-setup
# .claude.localhost form, path-form routing, the index page, the /.cc API,
# raw TCP forward allocation (--service-port), the DNS server, live service
# declaration with no restarts, and error paths.
#
# Also covers the launcher-level bits with a stubbed docker: ephemeral mux
# publish, container naming, and registry registration/deregistration.
#
# Usage: tests/test-services.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"
ROUTER="$REPO_DIR/bin/claude-container-router"
MUX="$REPO_DIR/claude-code/svc-mux"

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_eq() { # desc got want
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (got: '$2', want: '$3')"
    fi
}

assert_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (needle '$3' not in output)"; echo "---"; echo "$2" | head -5; echo "---" ;;
    esac
}

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_port() { # port [tries]
    local i
    for i in $(seq 1 "${2:-50}"); do
        if python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=0.2)' "$1" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# --- Fixture: workspace, two backend HTTP services, mux, registry, router -----

WS="$TMP/myws"
mkdir -p "$WS/.claude-container-overlay" "$TMP/docroot1" "$TMP/docroot2"
echo "hello-from-web" > "$TMP/docroot1/hello.txt"
echo "hello-from-web2" > "$TMP/docroot2/hello.txt"

SVC1_PORT=$(free_port)
(cd "$TMP/docroot1" && exec python3 -m http.server "$SVC1_PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
PIDS+=($!)

# Only service "web" is declared up front; "web2" is added live later.
cat > "$WS/.claude-container-overlay/overlay.json" <<EOF
{"services": {"web": $SVC1_PORT}}
EOF

MUX_PORT=$(free_port)
CLAUDE_SVC_OVERLAY_JSON="$WS/.claude-container-overlay/overlay.json" \
    CLAUDE_SVC_MUX_PORT="$MUX_PORT" python3 "$MUX" >/dev/null 2>&1 &
PIDS+=($!)

CONFIG_BASE="$TMP/config"
mkdir -p "$CONFIG_BASE/services"
cat > "$CONFIG_BASE/services/myws.json" <<EOF
{"name": "myws", "workspace": "$WS", "container": "cc-test", "mux_port": $MUX_PORT}
EOF

HTTP_PORT=$(free_port)
ALT_PORT=$(free_port)
DNS_PORT=$(free_port)
export CLAUDE_CONTAINER_CONFIG_BASE="$CONFIG_BASE"
export CLAUDE_ROUTER_HTTP_PORT="$HTTP_PORT"
export CLAUDE_ROUTER_DNS_PORT="$DNS_PORT"
# One bindable alt port (stands in for port 80) and one already-occupied port
# (the backend's) to exercise the graceful-skip path.
export CLAUDE_ROUTER_HTTP_ALT_PORTS="$SVC1_PORT,$ALT_PORT"
python3 "$ROUTER" run > "$TMP/router.log" 2>&1 &
PIDS+=($!)

if ! wait_port "$SVC1_PORT" || ! wait_port "$MUX_PORT" || ! wait_port "$HTTP_PORT"; then
    echo "FATAL: fixture did not come up (see $TMP/router.log)"
    cat "$TMP/router.log"
    exit 1
fi

echo "== mux protocol =="

out=$(python3 - "$MUX_PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)
s.sendall(b"web\n")
f = s.makefile("rb")
print(f.readline().decode().split()[0])
PY
)
assert_eq "mux answers OK for a declared service" "$out" "OK"

out=$(python3 - "$MUX_PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)
s.sendall(b"nope\n")
print(s.makefile("rb").readline().decode().strip())
PY
)
assert_contains "mux answers ERR for an unknown service" "$out" "ERR unknown service 'nope'"

echo "== HTTP front door =="

out=$(curl -s -H "Host: web.myws.claude" "http://127.0.0.1:$HTTP_PORT/hello.txt")
assert_eq "host-form routing (.claude)" "$out" "hello-from-web"

out=$(curl -s -H "Host: web.myws.claude.localhost" "http://127.0.0.1:$HTTP_PORT/hello.txt")
assert_eq "host-form routing (.claude.localhost, zero DNS setup)" "$out" "hello-from-web"

out=$(curl -s -H "Host: web.myws.claude:$HTTP_PORT" "http://127.0.0.1:$HTTP_PORT/hello.txt")
assert_eq "host-form routing tolerates port in Host header" "$out" "hello-from-web"

out=$(curl -s "http://127.0.0.1:$HTTP_PORT/myws/web/hello.txt")
assert_eq "path-form routing" "$out" "hello-from-web"

out=$(curl -s "http://127.0.0.1:$HTTP_PORT/")
assert_contains "index lists the instance" "$out" "myws"
assert_contains "index links the service host form" "$out" "web.myws.claude.localhost:$HTTP_PORT"

out=$(curl -s "http://127.0.0.1:$HTTP_PORT/.cc/services")
assert_contains "API lists declared services" "$out" '"web"'

out=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: nope.myws.claude" "http://127.0.0.1:$HTTP_PORT/")
assert_eq "unknown service is a 502" "$out" "502"

out=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: web.ghost.claude" "http://127.0.0.1:$HTTP_PORT/")
assert_eq "unknown instance is a 502" "$out" "502"

echo "== alternate HTTP ports (portless URLs) =="

out=$(curl -s -H "Host: web.myws.claude.localhost" "http://127.0.0.1:$ALT_PORT/hello.txt")
assert_eq "front door also serves the alt port (port-80 stand-in)" "$out" "hello-from-web"

out=$(curl -s "http://127.0.0.1:$HTTP_PORT/.cc/health")
assert_contains "health reports the bound alt port" "$out" "$ALT_PORT"

assert_contains "occupied alt port is skipped gracefully" "$(cat "$TMP/router.log")" "alt port 127.0.0.1:$SVC1_PORT unavailable"

echo "== raw TCP forward (--service-port) =="

fwd=$(python3 "$ROUTER" port myws/web)
if [ -n "$fwd" ] && wait_port "$fwd"; then
    pass "port command allocates a forward ($fwd)"
else
    fail "port command allocates a forward (got '$fwd')"
fi
out=$(curl -s "http://127.0.0.1:$fwd/hello.txt")
assert_eq "raw TCP forward pipes to the service" "$out" "hello-from-web"
fwd2=$(python3 "$ROUTER" port myws/web)
assert_eq "port command is idempotent" "$fwd2" "$fwd"

echo "== DNS =="

dns_query() { # name -> answer or rcode:N
    python3 - "$DNS_PORT" "$1" <<'PY'
import socket, struct, sys
port, name = int(sys.argv[1]), sys.argv[2]
q = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for label in name.split("."):
    q += bytes([len(label)]) + label.encode()
q += b"\x00" + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(q, ("127.0.0.1", port))
r, _ = s.recvfrom(1024)
rcode = r[3] & 0xF
ancount = struct.unpack("!H", r[6:8])[0]
if rcode or not ancount:
    print(f"rcode:{rcode}")
else:
    print(".".join(str(b) for b in r[-4:]))
PY
}

assert_eq "A query for a service name" "$(dns_query web.myws.claude)" "127.0.0.1"
assert_eq "A query for anything under .claude" "$(dns_query foo.bar.claude)" "127.0.0.1"
assert_eq "non-matching name is NXDOMAIN" "$(dns_query example.com)" "rcode:3"

echo "== live service declaration (no restarts) =="

SVC2_PORT=$(free_port)
(cd "$TMP/docroot2" && exec python3 -m http.server "$SVC2_PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
PIDS+=($!)
wait_port "$SVC2_PORT" || fail "second backend did not start"

cat > "$WS/.claude-container-overlay/overlay.json" <<EOF
{"services": {"web": $SVC1_PORT, "web2": $SVC2_PORT}}
EOF

out=$(curl -s -H "Host: web2.myws.claude" "http://127.0.0.1:$HTTP_PORT/hello.txt")
assert_eq "service added to overlay.json works immediately" "$out" "hello-from-web2"

echo "== launcher registration (stub docker) =="

# Stub docker that reports a running container and a fake ephemeral mux port.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    port) echo "127.0.0.1:45678"; exit 0 ;;
    ps) echo "cc-should-be-pruned"; exit 0 ;;
    run) echo "DOCKER-RUN: \$*"; sleep 2; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

LAUNCH_HOME="$TMP/home"
mkdir -p "$LAUNCH_HOME"
WS2="$TMP/worktree-a"
mkdir -p "$WS2"
# A stale registration whose container is not in `docker ps` output.
mkdir -p "$LAUNCH_HOME/.config/claude-container/services"
cat > "$LAUNCH_HOME/.config/claude-container/services/stale.json" <<EOF
{"name": "stale", "workspace": "/gone", "container": "cc-dead", "mux_port": 1}
EOF

# Run the launcher against the stub (its `run` lingers like a real session,
# pointing --router at the already-running router so `ensure` is a no-op) and
# observe the registration while the "session" is live.
REG="$LAUNCH_HOME/.config/claude-container/services/worktree-a.json"
(cd "$WS2" && HOME="$LAUNCH_HOME" PATH="$TMP/bin:$PATH" \
    CLAUDE_ROUTER_HTTP_PORT="$HTTP_PORT" bash "$LAUNCHER" true > "$TMP/launcher.out" 2>&1) &
LAUNCHER_PID=$!
for _ in $(seq 1 30); do
    [ -f "$REG" ] && break
    sleep 0.2
done
if [ -f "$REG" ]; then
    pass "instance is registered while the session runs"
    assert_eq "registration records the ephemeral mux port" \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mux_port"])' "$REG")" "45678"
else
    fail "instance is registered while the session runs"
fi
if [ -f "$LAUNCH_HOME/.config/claude-container/services/stale.json" ]; then
    fail "stale registration is pruned at launch"
else
    pass "stale registration is pruned at launch"
fi
wait "$LAUNCHER_PID" 2>/dev/null
run_out=$(cat "$TMP/launcher.out")
assert_contains "launcher names the container" "$run_out" "--name cc-worktree-a-"
assert_contains "launcher publishes the mux ephemerally" "$run_out" "-p 127.0.0.1::7999"
assert_contains "launcher passes the instance name into the container" "$run_out" "CLAUDE_SERVICE_INSTANCE=worktree-a"
if [ -f "$REG" ]; then
    fail "registration is removed on exit"
else
    pass "registration is removed on exit"
fi

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
