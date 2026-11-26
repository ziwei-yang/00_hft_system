#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 02 (timezone, base packages, libdpdk, liburing, cron).
# NEVER writes any file and NEVER mutates system state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged|--live) shift ;;
        -h|--help)
            echo "Usage: verify_02_base_packages_and_tz.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. Timezone
TZ_VAL="$("$HFT_TIMEDATECTL_CMD" show -p Timezone --value 2>/dev/null || true)"
if [[ -z "$TZ_VAL" && -r "${HFT_ROOT}/etc/timezone" ]]; then
    TZ_VAL="$(tr -d '[:space:]' < "${HFT_ROOT}/etc/timezone")"
fi
if [[ "$TZ_VAL" == "Asia/Hong_Kong" ]]; then
    pass_check "Timezone is Asia/Hong_Kong"
else
    fail_check "Timezone mismatch (got '${TZ_VAL:-unknown}', expected Asia/Hong_Kong)"
fi

# 2. Required packages
REQUIRED_PKGS=(
    build-essential g++ gcc make cmake pkg-config autoconf automake libtool
    git ca-certificates liburing-dev zlib1g-dev libssl-dev dpdk libdpdk-dev
    python3 python3-pip python3-venv cron ethtool iproute2 net-tools tcpdump
    curl wget jq tmux htop sysstat numactl rsync unzip openssh-client
)

declare -a MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    status="$("$HFT_DPKG_CMD" -s "$pkg" 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
    if [[ "$status" != "install ok installed" ]]; then
        MISSING+=("$pkg")
    fi
done
if (( ${#MISSING[@]} == 0 )); then
    pass_check "All ${#REQUIRED_PKGS[@]} required dpkg packages are installed"
else
    fail_check "Missing dpkg packages: ${MISSING[*]}"
fi

# 3. pkg-config --exists libdpdk
if "$HFT_PKG_CONFIG_CMD" --exists libdpdk 2>/dev/null; then
    pass_check "pkg-config --exists libdpdk"
else
    fail_check "pkg-config --exists libdpdk failed"
fi

# 4. -luring compile+link probe (pure read-only: stdin -> /dev/null)
if printf '#include <liburing.h>\nint main(void){ struct io_uring r; (void)r; return 0; }\n' | "$HFT_CC_CMD" -x c - -luring -o /dev/null 2>/dev/null; then
    pass_check "liburing compile/link probe (-luring) passed"
else
    fail_check "liburing compile/link probe (-luring) failed"
fi

# 5. cron active + enabled
cron_act="$("$HFT_SYSTEMCTL_CMD" is-active cron 2>/dev/null || true)"
cron_en="$("$HFT_SYSTEMCTL_CMD" is-enabled cron 2>/dev/null || true)"
if [[ "$cron_act" == "active" && "$cron_en" == "enabled" ]]; then
    pass_check "cron service is active and enabled"
else
    fail_check "cron service state invalid (active=${cron_act:-unknown}, enabled=${cron_en:-unknown})"
fi

if (( FAIL > 0 )); then
    log_error "verify_02_base_packages_and_tz: ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_02_base_packages_and_tz: ALL CHECKS PASSED."
