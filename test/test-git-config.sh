#!/bin/bash
#
# Test --git-config and -g flag git identity injection in run-llm-cli.sh.
#
# These tests do NOT build or run containers — they validate that the
# podman command constructed by run-llm-cli.sh includes the correct
# GIT_AUTHOR_* / GIT_COMMITTER_* environment variables.
#
# Usage: ./test/test-git-config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUN_SCRIPT="$PROJECT_DIR/run-llm-cli.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

passed=0
failed=0

pass() { echo -e "  ${GREEN}PASS${RESET} $1"; ((passed++)) || true; }
fail() { echo -e "  ${RED}FAIL${RESET} $1"; ((failed++)) || true; }
log()  { echo -e "${BOLD}==> $1${RESET}"; }

# Run run-llm-cli.sh with fake `podman` (and optionally fake `git`) in PATH.
# Fake podman writes all args to a temp file instead of running containers.
# Returns the captured podman args on stdout.
#
# Usage: capture_podman_args [--fake-git-name NAME --fake-git-email EMAIL] -- <script args...>
capture_podman_args() {
    local fake_git_name="" fake_git_email=""

    while [[ $# -gt 0 && "$1" != "--" ]]; do
        case "$1" in
            --fake-git-name)  fake_git_name="$2";  shift 2 ;;
            --fake-git-email) fake_git_email="$2"; shift 2 ;;
            *) echo "capture_podman_args: unknown option $1" >&2; return 1 ;;
        esac
    done
    shift  # consume "--"

    local tmpbin args_file
    tmpbin="$(mktemp -d)"
    args_file="$(mktemp)"

    # Fake podman: record args and dump content of any mounted credential files
    cat > "$tmpbin/podman" <<PODMAN_EOF
#!/bin/bash
echo "\$*" >> "$args_file"
# Dump content of any mounted .git-credentials or .gitconfig so tests can inspect them
args=("\$@")
for i in "\${!args[@]}"; do
    arg="\${args[\$i]}"
    if [[ "\$arg" == *":/root/.git-credentials:"* ]]; then
        src="\${arg%%:*}"
        echo "CREDS_CONTENT:\$(cat "\$src")" >> "$args_file"
    fi
    if [[ "\$arg" == *":/root/.gitconfig:"* ]]; then
        src="\${arg%%:*}"
        echo "GITCFG_CONTENT:\$(cat "\$src")" >> "$args_file"
    fi
done
PODMAN_EOF
    chmod +x "$tmpbin/podman"

    # Fake git: return controlled user.name / user.email values when requested
    if [ -n "$fake_git_name" ] || [ -n "$fake_git_email" ]; then
        cat > "$tmpbin/git" <<EOF
#!/bin/bash
if [[ "\$*" == *"user.name"* ]];  then echo "$fake_git_name";  exit 0; fi
if [[ "\$*" == *"user.email"* ]]; then echo "$fake_git_email"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
        chmod +x "$tmpbin/git"
    fi

    PATH="$tmpbin:$PATH" bash "$RUN_SCRIPT" "$@" 2>/dev/null || true

    cat "$args_file"
    rm -f "$args_file"
    rm -rf "$tmpbin"
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$label"
    else
        fail "$label"
        echo "    expected : $needle"
        echo "    in args  : $haystack"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        pass "$label"
    else
        fail "$label"
        echo "    did not expect: $needle"
        echo "    in args       : $haystack"
    fi
}

# ---------------------------------------------------------------------------
log "--git-config sets author and email"
args=$(capture_podman_args -- --no-build --git-config "author=llm-bot,email=llm@example.com")
assert_contains "GIT_AUTHOR_NAME=llm-bot"             "GIT_AUTHOR_NAME=llm-bot"             "$args"
assert_contains "GIT_COMMITTER_NAME=llm-bot"          "GIT_COMMITTER_NAME=llm-bot"          "$args"
assert_contains "GIT_AUTHOR_EMAIL=llm@example.com"    "GIT_AUTHOR_EMAIL=llm@example.com"    "$args"
assert_contains "GIT_COMMITTER_EMAIL=llm@example.com" "GIT_COMMITTER_EMAIL=llm@example.com" "$args"

# ---------------------------------------------------------------------------
log "--git-config order independence (email before author)"
args=$(capture_podman_args -- --no-build --git-config "email=bot@ci.com,author=ci-bot")
assert_contains "GIT_AUTHOR_NAME=ci-bot"      "GIT_AUTHOR_NAME=ci-bot"      "$args"
assert_contains "GIT_AUTHOR_EMAIL=bot@ci.com" "GIT_AUTHOR_EMAIL=bot@ci.com" "$args"

# ---------------------------------------------------------------------------
log "-g reads identity from host gitconfig"
args=$(capture_podman_args \
    --fake-git-name "Host User" --fake-git-email "host@user.com" \
    -- --no-build -g)
assert_contains "GIT_AUTHOR_NAME=Host User"      "GIT_AUTHOR_NAME=Host User"      "$args"
assert_contains "GIT_COMMITTER_NAME=Host User"   "GIT_COMMITTER_NAME=Host User"   "$args"
assert_contains "GIT_AUTHOR_EMAIL=host@user.com" "GIT_AUTHOR_EMAIL=host@user.com" "$args"

# ---------------------------------------------------------------------------
log "--git-config overrides -g identity when both are passed"
args=$(capture_podman_args \
    --fake-git-name "Host User" --fake-git-email "host@user.com" \
    -- --no-build -g --git-config "author=llm-bot,email=llm@example.com")
assert_contains     "custom identity used"  "GIT_AUTHOR_NAME=llm-bot"   "$args"
assert_not_contains "host identity absent"  "GIT_AUTHOR_NAME=Host User" "$args"

# ---------------------------------------------------------------------------
log "--git-token plain token uses x-access-token and github.com"
args=$(capture_podman_args -- --no-build --git-token "ghp_testtoken123")
assert_contains "credentials file mounted"  "/root/.git-credentials"                      "$args"
assert_contains "gitconfig injected"        "/root/.gitconfig"                             "$args"
assert_contains "correct credentials entry" "CREDS_CONTENT:https://x-access-token:ghp_testtoken123@github.com" "$args"
assert_contains "credential.helper in cfg"  "GITCFG_CONTENT:[credential]"                 "$args"

# ---------------------------------------------------------------------------
log "--git-token user:token format splits username"
args=$(capture_podman_args -- --no-build --git-token "myuser:mytoken")
assert_contains "correct user in creds" "CREDS_CONTENT:https://myuser:mytoken@github.com" "$args"

# ---------------------------------------------------------------------------
log "--git-host changes the target host"
args=$(capture_podman_args -- --no-build --git-token "mytoken" --git-host "gitlab.com")
assert_contains "host in creds" "CREDS_CONTENT:https://x-access-token:mytoken@gitlab.com" "$args"

# ---------------------------------------------------------------------------
log "--git-token with -g does not inject a second gitconfig"
args=$(capture_podman_args -- --no-build -g --git-token "ghp_testtoken123")
assert_contains     "credentials file still mounted" "/root/.git-credentials"  "$args"
assert_not_contains "no injected minimal gitconfig"  "GITCFG_CONTENT"          "$args"

# ---------------------------------------------------------------------------
log "no git flags = no GIT_AUTHOR_* vars injected"
args=$(capture_podman_args -- --no-build)
assert_not_contains "no GIT_AUTHOR_NAME"  "GIT_AUTHOR_NAME"  "$args"
assert_not_contains "no GIT_AUTHOR_EMAIL" "GIT_AUTHOR_EMAIL" "$args"

# ---------------------------------------------------------------------------
echo ""
log "Results: ${GREEN}${passed} passed${RESET}, ${RED}${failed} failed${RESET}"
[ "$failed" -eq 0 ] && exit 0 || exit 1
