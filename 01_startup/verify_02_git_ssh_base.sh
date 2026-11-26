#!/usr/bin/env bash
# Pure read-only verifier for Layer 2 Step 02 (Git defaults, ~/.ssh/config.d, GitHub known_hosts).
# Strictly zero sudo, non-root, NEVER writes any file.
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. Git defaults
check_git_cfg() {
    local key="$1" expected="$2"
    local actual
    actual="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
        pass_check "git config --global $key = $expected"
    else
        fail_check "git config --global $key mismatch (got '${actual:-unset}', expected '$expected')"
    fi
}

check_git_cfg init.defaultBranch main
check_git_cfg pull.ff only
check_git_cfg fetch.prune true

# 2. ~/.ssh/config.d (0700) and ~/.ssh/config (0600)
SSH_CONF_D="${HOME}/.ssh/config.d"
SSH_CONF="${HOME}/.ssh/config"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

if [[ -d "$SSH_CONF_D" ]]; then
    m="$(stat_mode "$SSH_CONF_D" || true)"
    if [[ "$m" == "700" || "$m" == "0700" ]]; then
        pass_check "$SSH_CONF_D exists with mode $m"
    else
        fail_check "$SSH_CONF_D mode is '${m:-?}' (expected 700)"
    fi
else
    fail_check "Missing $SSH_CONF_D"
fi

if [[ -r "$SSH_CONF" ]]; then
    m="$(stat_mode "$SSH_CONF" || true)"
    if [[ "$m" == "600" || "$m" == "0600" ]]; then
        pass_check "$SSH_CONF mode is $m"
    else
        fail_check "$SSH_CONF mode is '${m:-?}' (expected 600)"
    fi
    if grep -Fqx "Include ~/.ssh/config.d/*.conf" "$SSH_CONF"; then
        pass_check "$SSH_CONF includes ~/.ssh/config.d/*.conf"
    else
        fail_check "$SSH_CONF missing 'Include ~/.ssh/config.d/*.conf'"
    fi
else
    fail_check "Missing or unreadable $SSH_CONF"
fi

# 3. GitHub ED25519 + RSA host keys in known_hosts
GH_ED25519="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
GH_RSA="github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="

if [[ -r "$KNOWN_HOSTS" ]]; then
    if grep -Fqx "$GH_ED25519" "$KNOWN_HOSTS"; then
        pass_check "known_hosts contains official GitHub ED25519 host key"
    else
        fail_check "known_hosts missing official GitHub ED25519 host key"
    fi
    if grep -Fqx "$GH_RSA" "$KNOWN_HOSTS"; then
        pass_check "known_hosts contains official GitHub RSA host key"
    else
        fail_check "known_hosts missing official GitHub RSA host key"
    fi
else
    fail_check "Missing or unreadable $KNOWN_HOSTS"
fi

if (( FAIL > 0 )); then
    log_error "verify_02_git_ssh_base: ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_02_git_ssh_base: ALL CHECKS PASSED."
