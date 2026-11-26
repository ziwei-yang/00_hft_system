#!/usr/bin/env bash
# Pure read-only verifier for Layer 2 Step 01 (user workspace dirs & perms).
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

for d in "${HOME}/Proj" "${HOME}/etc" "${HOME}/log" "${HOME}/.config/hft" "${HOME}/.config/systemd/user" "${HOME}/.ssh"; do
    if [[ -d "$d" ]]; then
        pass_check "Directory exists: $d"
    else
        fail_check "Missing directory: $d"
    fi
done

for sd in "${HOME}/.config/hft" "${HOME}/.ssh"; do
    if [[ -d "$sd" ]]; then
        m="$(stat_mode "$sd" || true)"
        if [[ "$m" == "700" || "$m" == "0700" ]]; then
            pass_check "Directory $sd has mode $m"
        else
            fail_check "Directory $sd has mode '${m:-?}' (expected 700)"
        fi
    fi
done

if (( FAIL > 0 )); then
    log_error "verify_01_user_workspace: ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_01_user_workspace: ALL CHECKS PASSED."
