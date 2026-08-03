#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../setup.sh
source "$REPO_ROOT/setup.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" label="$3"
    [ "$expected" = "$actual" ] || fail "$label (expected '$expected', got '$actual')"
}

test_fresh_server_uses_root() {
    SERVER_IP="203.0.113.10"
    NEW_USER="ubuntu"
    REMOTE_USER=""
    IS_RESUME=false
    ssh() {
        [[ "$*" == *"root@203.0.113.10"* ]]
    }
    sleep() { :; }

    wait_for_server >/dev/null
    assert_equal "root" "$REMOTE_USER" "fresh server login"
}

test_hardened_server_uses_service_user() {
    SERVER_IP="203.0.113.11"
    NEW_USER="ubuntu"
    REMOTE_USER=""
    IS_RESUME=true
    ssh() {
        [[ "$*" == *"ubuntu@203.0.113.11"* ]]
    }
    sleep() { :; }

    wait_for_server >/dev/null
    assert_equal "ubuntu" "$REMOTE_USER" "resume login after root is disabled"
}

test_resumed_setup_uses_sudo() {
    local calls seen_key=""
    calls=$(mktemp)
    trap 'rm -f "$calls"' RETURN
    SERVER_IP="203.0.113.12"
    NEW_USER="ubuntu"
    REMOTE_USER="ubuntu"
    DODO_SSH_KEY="/tmp/key with spaces"
    ssh() {
        local previous="" argument
        for argument in "$@"; do
            if [ "$previous" = "-i" ]; then
                seen_key="$argument"
            fi
            previous="$argument"
        done
        printf '%s\n' "$*" >> "$calls"
        return 0
    }

    run_remote_setup >/dev/null
    assert_equal "$DODO_SSH_KEY" "$seen_key" "SSH key argument boundary"
    grep -q "IdentitiesOnly=yes" "$calls" || fail "SSH did not restrict identity offers"
    grep -q "ubuntu@203.0.113.12" "$calls" || fail "resume target was not the service user"
    grep -q "sudo env NEW_USER=ubuntu" "$calls" || fail "resumed server setup did not elevate with sudo"
}

test_readiness_timeout_is_bounded() {
    local output status
    set +e
    output=$(
        SERVER_IP="203.0.113.14"
        NEW_USER="ubuntu"
        ssh() { return 1; }
        sleep() { :; }
        wait_for_server
    2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "unreachable server should time out"
    [[ "$output" == *"60/60"* ]] || fail "readiness timeout did not stop after 60 rounds"
    [[ "$output" == *"did not become reachable after 5 minutes"* ]] || fail "readiness timeout message missing"
}

test_download_failure_prints_same_server_retry() {
    local output status
    set +e
    output=$(
        SERVER_IP="203.0.113.13"
        NEW_USER="ubuntu"
        REMOTE_USER="ubuntu"
        DODO_SSH_KEY="/tmp/key with spaces"
        ssh() { [[ "$*" == *"sudo -n true"* ]]; }
        run_remote_setup
    2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "failed remote download should stop setup"
    [[ "$output" == *"EXISTING_SERVER_IP=203.0.113.13"* ]] || fail "download failure omitted same-server retry"
    [[ "$output" == *"NEW_USER=ubuntu"* ]] || fail "download failure omitted the service user"
    [[ "$output" == *"INSTALL_TAILSCALE=false"* ]] || fail "download failure omitted install choices"
    [[ "$output" == *"No new server is needed"* || "$output" == *"no new server is needed"* ]] || fail "download failure did not preserve the VPS"
}

test_windows_git_bash_fails_with_guidance() {
    local output status
    set +e
    output=$(
        uname() { echo "MINGW64_NT-10.0"; }
        local_main
    2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "Git Bash launcher should fail fast"
    [[ "$output" == *"Use setup.ps1 from PowerShell on Windows"* ]] || fail "Git Bash guidance missing"
}

assert_equal "main" "$DODO_VPS_VERSION" "default update channel"
if DODO_VPS_VERSION='main;touch-bad' bash "$REPO_ROOT/setup.sh" --help >/dev/null 2>&1; then
    fail "unsafe DODO_VPS_VERSION should be rejected"
fi
if DODO_VPS_VERSION='../other-repo' bash "$REPO_ROOT/setup.sh" --help >/dev/null 2>&1; then
    fail "path-traversing DODO_VPS_VERSION should be rejected"
fi
test_fresh_server_uses_root
test_hardened_server_uses_service_user
test_resumed_setup_uses_sudo
test_download_failure_prints_same_server_retry
test_readiness_timeout_is_bounded
test_windows_git_bash_fails_with_guidance

echo "All Bash compatibility tests passed."
