#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 06 (bg apt noise disabled, journald capped).
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
            echo "Usage: verify_06_disable_bg_noise.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. Verify noise units stopped & masked (or not-found)
for unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
    act="$("$HFT_SYSTEMCTL_CMD" is-active "$unit" 2>/dev/null || true)"
    [[ -z "$act" ]] && act="inactive"
    en="$("$HFT_SYSTEMCTL_CMD" is-enabled "$unit" 2>/dev/null || true)"
    [[ -z "$en" ]] && en="not-found"
    if [[ "$act" != "active" && ( "$en" == "masked" || "$en" == "not-found" ) ]]; then
        pass_check "$unit inactive and masked/not-found (active=$act enabled=$en)"
    else
        fail_check "$unit not disabled/masked (active=$act enabled=$en)"
    fi
done

# 2. Verify /etc/apt/apt.conf.d/20auto-upgrades
AUTO_UPG="${HFT_ROOT}/etc/apt/apt.conf.d/20auto-upgrades"
if [[ -r "$AUTO_UPG" ]] \
   && grep -Eq 'APT::Periodic::Update-Package-Lists[[:space:]]+"0";' "$AUTO_UPG" \
   && grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"0";' "$AUTO_UPG"; then
    pass_check "$AUTO_UPG disables periodic updates and unattended upgrades"
else
    fail_check "$AUTO_UPG missing or does not disable both periodic settings"
fi

# 3. Verify /etc/systemd/journald.conf.d/99-hft.conf
JOURNAL_CONF="${HFT_ROOT}/etc/systemd/journald.conf.d/99-hft.conf"
if [[ -r "$JOURNAL_CONF" ]] \
   && grep -Fq 'SystemMaxUse=500M' "$JOURNAL_CONF" \
   && grep -Fq 'MaxRetentionSec=14day' "$JOURNAL_CONF"; then
    pass_check "$JOURNAL_CONF caps journald size and retention"
else
    fail_check "$JOURNAL_CONF missing or incomplete"
fi

# 4. Verify systemd-journald active
j_act="$("$HFT_SYSTEMCTL_CMD" is-active systemd-journald 2>/dev/null || true)"
if [[ "$j_act" == "active" ]]; then
    pass_check "systemd-journald is active"
else
    fail_check "systemd-journald is not active (state=${j_act:-unknown})"
fi

if (( FAIL > 0 )); then
    log_error "verify_06_disable_bg_noise: ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_06_disable_bg_noise: ALL CHECKS PASSED."
