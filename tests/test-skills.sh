#!/bin/bash
#
# Tests for the launcher's skill-sharing and directory-overlay features.
#
# Self-contained: runs the real launcher against a stub `docker` and an
# isolated $HOME under a temp dir, so no images are built and no containers
# are started. The interactive-prompt test needs `expect` and is skipped if
# it isn't installed.
#
# Usage: tests/test-skills.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
CONFIG_SKILLS="$HOME/.config/claude-container/config/skills"
USER_SKILLS="$HOME/.config/claude-container/user-skills"
CHOICES="$HOME/.config/claude-container/skill-choices"

# Stub docker: `info` succeeds, `image inspect` always misses (forces the build
# path), `build` records the effective Dockerfile (stdin with `-f -`, otherwise
# the context dir's Dockerfile), `run` echoes its args so tests can assert on
# -p flags and the image tag.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    build)
        ctx="\${@: -1}"
        case " \$* " in
            *" -f - "*) cat > "$TMP/dockerfile-fed" 2>/dev/null ;;
            *) cp "\$ctx/Dockerfile" "$TMP/dockerfile-fed" 2>/dev/null ;;
        esac
        echo "DOCKER-BUILD: \$*"
        exit 0
        ;;
    run) echo "DOCKER-RUN: \$*"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (missing: $3)" ;;
    esac
}

assert_not_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) fail "$1 (unexpected: $3)" ;;
        *) pass "$1" ;;
    esac
}

assert_exists() { # desc path
    if [ -e "$2" ]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

assert_missing() { # desc path
    if [ -e "$2" ]; then fail "$1 (still exists: $2)"; else pass "$1"; fi
}

assert_exit() { # desc expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected exit $2, got $3)"; fi
}

write_skill() { # dir name
    mkdir -p "$1/$2"
    printf -- '---\nname: %s\ndescription: Test skill %s.\n---\n\n# %s\nbody\n' "$2" "$2" "$2" > "$1/$2/SKILL.md"
}

launch() { # workspace [args...] -> stdout+stderr, non-interactive
    local ws="$1"; shift
    bash "$LAUNCHER" -w "$ws" "$@" < /dev/null 2>&1
}

overlay_hash() { # launch output -> hash tag
    printf '%s' "$1" | grep -o 'claude-container-overlay:[a-f0-9]*' | head -1
}

WS1="$TMP/ws1"
WS2="$TMP/ws2"
mkdir -p "$WS1" "$WS2"


echo "== directory overlay: build, ports, workspace skill deployment =="
mkdir -p "$WS1/.claude-container-overlay"
printf 'RUN echo overlay-build-step\n' > "$WS1/.claude-container-overlay/Dockerfile"
printf '{ "ports": ["8080:8080", "127.0.0.1:3000:3000"] }\n' > "$WS1/.claude-container-overlay/overlay.json"
write_skill "$WS1/.claude-container-overlay/skills" my-skill

OUT="$(launch "$WS1")"
assert_contains "workspace skill deployed" "$OUT" "Skills deployed for this project"
assert_contains "adoption hint printed" "$OUT" "--skills-adopt my-skill"
assert_contains "ports published" "$OUT" "-p 8080:8080 -p 127.0.0.1:3000:3000"
assert_contains "overlay image used for run" "$OUT" "DOCKER-RUN: run --rm -it"
assert_exists "skill copied into config skills" "$CONFIG_SKILLS/my-skill/SKILL.md"
assert_exists "manifest written" "$CONFIG_SKILLS/.claude-container-managed"
assert_contains "manifest lists skill" "$(cat "$CONFIG_SKILLS/.claude-container-managed")" "my-skill"
assert_contains "FROM prepended to fragment" "$(cat "$TMP/dockerfile-fed")" "FROM nezhar/claude-container"
assert_contains "fragment fed to build" "$(cat "$TMP/dockerfile-fed")" "RUN echo overlay-build-step"
HASH1="$(overlay_hash "$OUT")"


echo "== hash stability: runtime-only changes never rebuild =="
printf '{ "ports": ["9999:9999"] }\n' > "$WS1/.claude-container-overlay/overlay.json"
write_skill "$WS1/.claude-container-overlay/skills" second-skill
HASH2="$(overlay_hash "$(launch "$WS1")")"
if [ "$HASH1" = "$HASH2" ]; then
    pass "ports/skills changes keep hash ($HASH1)"
else
    fail "ports/skills changes changed hash ($HASH1 -> $HASH2)"
fi
printf 'context-file\n' > "$WS1/.claude-container-overlay/some.conf"
HASH3="$(overlay_hash "$(launch "$WS1")")"
if [ "$HASH1" != "$HASH3" ]; then
    pass "extra context file changes hash"
else
    fail "extra context file did not change hash"
fi
rm "$WS1/.claude-container-overlay/some.conf"
rm -rf "$WS1/.claude-container-overlay/skills/second-skill"


echo "== skills management commands =="
OUT="$(launch "$WS1" --skills)"
assert_contains "--skills lists workspace skill" "$OUT" "my-skill"
assert_contains "--skills shows adopt hint" "$OUT" "--skills-adopt my-skill"

OUT="$(launch "$WS1" --skills-adopt my-skill)"
assert_contains "adopt reports success" "$OUT" "Adopted 'my-skill'"
assert_exists "adopted into user-wide set" "$USER_SKILLS/my-skill/SKILL.md"
assert_contains "adopting project auto-accepts" "$(cat "$CHOICES"/ws1-*.conf)" "my-skill=accept"

OUT="$(launch "$WS1" --skills-adopt does-not-exist)"; RC=$?
assert_exit "adopt of unknown skill fails" 1 "$RC"

OUT="$(launch "$WS2" --skills-reject my-skill)"
assert_contains "reject records choice" "$OUT" "rejected for this project"
assert_contains "reject persisted" "$(cat "$CHOICES"/ws2-*.conf)" "my-skill=reject"
OUT="$(launch "$WS2" --skills)"
assert_contains "--skills shows rejected state" "$OUT" "rejected"

# ws2 launch: rejected user-wide skill, no workspace skills -> the previously
# managed deployment is cleaned up (shared config dir syncs to last launch).
OUT="$(launch "$WS2")"
assert_not_contains "rejected skill not deployed" "$OUT" "Skills deployed"
assert_missing "managed copy cleaned up" "$CONFIG_SKILLS/my-skill"
assert_missing "manifest removed when empty" "$CONFIG_SKILLS/.claude-container-managed"

OUT="$(launch "$WS2" --skills-accept my-skill)"
assert_contains "accept records choice" "$OUT" "accepted for this project"
OUT="$(launch "$WS2")"
assert_contains "accepted skill deployed" "$OUT" "Skills deployed for this project"
assert_exists "accepted copy in config skills" "$CONFIG_SKILLS/my-skill/SKILL.md"

OUT="$(launch "$WS2" --skills-reset)"
assert_contains "reset clears choices" "$OUT" "Cleared this project's skill choices"
assert_missing "choices file removed" "$(printf '%s' "$CHOICES"/ws2-*.conf)"

OUT="$(launch "$WS2" --skills-drop my-skill)"
assert_contains "drop removes user-wide skill" "$OUT" "Removed 'my-skill'"
assert_missing "user-wide copy gone" "$USER_SKILLS/my-skill"
OUT="$(launch "$WS2")"
assert_missing "dropped skill cleaned from config" "$CONFIG_SKILLS/my-skill"

OUT="$(bash "$LAUNCHER" -w "$WS2" --skills-accept < /dev/null 2>&1)"; RC=$?
assert_exit "missing skill name is an error" 1 "$RC"


echo "== reserved and invalid names =="
write_skill "$WS2/.claude-container-overlay/skills" container-tmux
mkdir -p "$WS2/.claude-container-overlay/skills/Bad_Name"
printf -- '---\nname: bad\ndescription: bad.\n---\n' > "$WS2/.claude-container-overlay/skills/Bad_Name/SKILL.md"
OUT="$(launch "$WS2")"
assert_contains "bundled name skipped" "$OUT" "reserved by an image-bundled skill"
assert_contains "invalid name skipped" "$OUT" "names must be lowercase"
assert_missing "reserved name not deployed" "$CONFIG_SKILLS/container-tmux"
rm -rf "$WS2/.claude-container-overlay"

OUT="$(launch "$WS2" --skills-adopt container-overlay)"; RC=$?
assert_exit "adopting reserved name fails" 1 "$RC"


echo "== legacy single-file overlay =="
WS3="$TMP/ws3"
mkdir -p "$WS3"
printf '# claude-container:port 9000:9000/udp\nRUN echo legacy-step\n' > "$WS3/.claude-container-overlay"
OUT="$(launch "$WS3")"
assert_contains "migration hint printed" "$OUT" "single-file overlays still work"
assert_contains "legacy port directive honored" "$OUT" "-p 9000:9000/udp"
assert_contains "legacy overlay built" "$OUT" "Building overlay image"
assert_contains "legacy fragment fed to build" "$(cat "$TMP/dockerfile-fed")" "RUN echo legacy-step"


echo "== worktrees inherit the main checkout's skill choices =="
if command -v git >/dev/null 2>&1; then
    write_skill "$USER_SKILLS" wt-skill
    MAIN="$TMP/wtmain"
    mkdir -p "$MAIN"
    git -C "$MAIN" init -q
    git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    WT="$TMP/wtlinked"
    git -C "$MAIN" worktree add -q "$WT" -b feature >/dev/null 2>&1

    # Accept the skill from the MAIN checkout, then launch the worktree: it must
    # reuse the same choices file (no re-prompt) and deploy the accepted skill.
    launch "$MAIN" --skills-accept wt-skill >/dev/null
    MAIN_CONF="$(printf '%s' "$CHOICES"/wtmain-*.conf)"
    assert_exists "main checkout choices file written" "$MAIN_CONF"

    OUT="$(launch "$WT")"
    assert_contains "worktree deploys the inherited skill" "$OUT" "Skills deployed for this project"
    assert_exists "no separate worktree choices file" "$MAIN_CONF"
    # The worktree must NOT have minted its own basename-keyed choices file.
    if compgen -G "$CHOICES/wtlinked-*.conf" >/dev/null; then
        fail "worktree created its own choices file instead of inheriting"
    else
        pass "worktree shares the main checkout's choices file"
    fi

    # A reject from the worktree flows back to the shared file the main sees.
    launch "$WT" --skills-reject wt-skill >/dev/null
    assert_contains "worktree reject lands in shared file" "$(cat "$MAIN_CONF")" "wt-skill=reject"
    OUT="$(launch "$MAIN")"
    assert_not_contains "main honors the worktree's reject" "$OUT" "Skills deployed"

    launch "$MAIN" --skills-drop wt-skill >/dev/null
    rm -f "$CHOICES"/wtmain-*.conf
else
    echo "  skip: git not installed; worktree inheritance test not run"
fi


echo "== --skills-ignore-new (non-interactive smoke) =="
# An undecided user-wide skill must not be deployed and must not record a choice
# when launching with --skills-ignore-new; the container still starts.
write_skill "$USER_SKILLS" ignore-me
WS_IGN="$TMP/wsign"
mkdir -p "$WS_IGN"
OUT="$(launch "$WS_IGN" --skills-ignore-new)"
assert_contains "flag accepted, container launches" "$OUT" "DOCKER-RUN: run"
assert_not_contains "undecided skill not deployed" "$OUT" "Skills deployed"
assert_missing "no choices file for an undecided skill" "$(printf '%s' "$CHOICES"/wsign-*.conf)"
launch "$WS_IGN" --skills-drop ignore-me >/dev/null


echo "== interactive prompt (sticky per-project choice) =="
if command -v expect >/dev/null 2>&1; then
    WS4="$TMP/ws4"
    mkdir -p "$WS4"
    write_skill "$USER_SKILLS" shared-skill
    cat > "$TMP/prompt.exp" <<EOF
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $LAUNCHER -w $WS4
expect "Include it in this project?" { send "x\r" }
expect "Please answer" { }
expect "Include it in this project?" { send "y\r" }
expect eof
EOF
    OUT="$(expect "$TMP/prompt.exp" 2>&1)"
    assert_contains "prompt shown for undecided skill" "$OUT" "New user-wide skill"
    assert_contains "invalid answer re-prompts" "$OUT" "Please answer y, n, or s"
    assert_contains "accepted skill deployed after prompt" "$OUT" "Skills deployed for this project"
    assert_contains "choice recorded sticky" "$(cat "$CHOICES"/ws4-*.conf)" "shared-skill=accept"
    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $LAUNCHER -w $WS4
expect eof
" 2>&1)"
    assert_not_contains "no re-prompt once decided" "$OUT" "Include it in this project?"

    # --skills-ignore-new must not prompt even on a tty, and must not record a
    # choice for the undecided skill (WS5 has never decided about shared-skill).
    WS5="$TMP/ws5"
    mkdir -p "$WS5"
    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $LAUNCHER -w $WS5 --skills-ignore-new
expect eof
" 2>&1)"
    assert_not_contains "--skills-ignore-new suppresses the prompt on a tty" "$OUT" "Include it in this project?"
    assert_contains "--skills-ignore-new still launches" "$OUT" "DOCKER-RUN: run"
    if compgen -G "$CHOICES/ws5-*.conf" >/dev/null; then
        fail "--skills-ignore-new recorded a choice for an undecided skill"
    else
        pass "--skills-ignore-new leaves undecided skills undecided"
    fi
else
    echo "  skip: expect not installed; prompt tests not run"
fi


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
