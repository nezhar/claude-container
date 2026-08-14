#!/bin/bash
#
# Launcher-level tests for git-worktree workspaces, with a stubbed docker.
# A linked worktree's .git is a pointer file into the main repository's .git
# directory, which lives outside the workspace bind mount — the launcher must
# also mount the main repo's .git at the path the pointer resolves to inside
# the container (same absolute path for absolute pointers, resolved against
# /workspace for relative ones). Regular repos and broken pointers must add no
# mount.
#
# Usage: tests/test-worktree.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (needle '$3' not in output)"; echo "---"; echo "$2" | head -5; echo "---" ;;
    esac
}

assert_not_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) fail "$1 (unexpected '$3' in output)"; echo "---"; echo "$2" | head -5; echo "---" ;;
        *) pass "$1" ;;
    esac
}

# Stub docker: `run` echoes its args so we can inspect the mounts; `port`
# fails so the background service registration never completes (and never
# tries to start a real router) before the launcher exits and reaps it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    port) exit 1 ;;
    ps) exit 0 ;;
    run) echo "DOCKER-RUN: $*"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

LAUNCH_HOME="$TMP/home"
mkdir -p "$LAUNCH_HOME"

launch() { # workspace-dir
    (cd "$1" && HOME="$LAUNCH_HOME" PATH="$TMP/bin:$PATH" bash "$LAUNCHER" true 2>&1)
}

launch_args() { # workspace-dir extra-args...
    local ws="$1"; shift
    (cd "$ws" && HOME="$LAUNCH_HOME" PATH="$TMP/bin:$PATH" bash "$LAUNCHER" "$@" true 2>&1)
}

# Fixture: a real main repo with one linked worktree.
MAIN="$TMP/mainrepo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$TMP/wt-a" -b wt-a-branch
MAIN_GIT="$(cd "$MAIN/.git" && pwd -P)"

echo "== worktree workspace (absolute gitdir pointer) =="
out=$(launch "$TMP/wt-a")
assert_contains "launcher announces the extra mount" "$out" "Git worktree workspace"
assert_contains "main .git is mounted at the same absolute path" "$out" "-v $MAIN_GIT:$MAIN_GIT"

echo "== worktree workspace (relative gitdir pointer) =="
# As written by worktree.useRelativePaths (git >= 2.48); crafted by hand so
# the test doesn't depend on the git version. The pointer resolves against
# /workspace in the container: /workspace/../mainrepo/.git/worktrees/wt-a,
# then commondir ../.. -> /mainrepo/.git.
printf 'gitdir: ../mainrepo/.git/worktrees/wt-a\n' > "$TMP/wt-a/.git"
out=$(launch "$TMP/wt-a")
assert_contains "relative pointer resolves against /workspace" "$out" "-v $MAIN_GIT:/mainrepo/.git"
git -C "$MAIN" worktree repair "$TMP/wt-a" 2>/dev/null

echo "== regular repo workspace =="
out=$(launch "$MAIN")
assert_not_contains "no extra mount for a regular repo" "$out" "Git worktree workspace"

echo "== broken worktree pointer =="
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"
printf 'gitdir: %s\n' "$TMP/nonexistent/.git/worktrees/x" > "$BROKEN/.git"
out=$(launch "$BROKEN")
assert_contains "dangling pointer warns instead of mounting" "$out" "doesn't resolve on the host"
assert_not_contains "dangling pointer adds no mount" "$out" "Git worktree workspace"

echo "== --mount adds a same-path bind mount =="
# A second, independent repo whose git dir the caller wants visible in the
# container at its identical host path (e.g. referenced by a sibling worktree).
OTHER="$TMP/otherrepo"
git init -q "$OTHER"
OTHER_GIT="$(cd "$OTHER/.git" && pwd -P)"
out=$(launch_args "$MAIN" --mount "$OTHER_GIT")
assert_contains "extra mount announced" "$out" "Extra bind mount (same path)"
assert_contains "host path bound at the identical path" "$out" "-v $OTHER_GIT:$OTHER_GIT"

echo "== --mount is repeatable =="
OTHER2="$TMP/otherrepo2"
mkdir -p "$OTHER2"
OTHER2_ABS="$(cd "$OTHER2" && pwd -P)"
out=$(launch_args "$MAIN" --mount "$OTHER_GIT" --mount "$OTHER2")
assert_contains "first mount present" "$out" "-v $OTHER_GIT:$OTHER_GIT"
assert_contains "second mount present" "$out" "-v $OTHER2_ABS:$OTHER2_ABS"

echo "== --mount skips a path inside the workspace =="
mkdir -p "$MAIN/subdir"
out=$(launch_args "$MAIN" --mount "$MAIN/subdir")
assert_contains "inside-workspace path is skipped" "$out" "already mounted"
assert_not_contains "no bind mount added for inside-workspace path" "$out" "-v $(cd "$MAIN/subdir" && pwd -P):"

echo "== --mount warns on a nonexistent path =="
out=$(launch_args "$MAIN" --mount "$TMP/does-not-exist")
assert_contains "nonexistent path warns" "$out" "does not exist on the host"

echo "== --mount without an argument errors =="
out=$( (cd "$MAIN" && HOME="$LAUNCH_HOME" PATH="$TMP/bin:$PATH" bash "$LAUNCHER" --mount 2>&1) )
assert_contains "missing --mount arg is rejected" "$out" "--mount requires a host path"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
