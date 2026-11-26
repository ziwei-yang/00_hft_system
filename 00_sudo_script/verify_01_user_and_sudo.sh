#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 01 (user 'hft', sudo, SSH keys, attestation).
# NEVER writes any file and NEVER mutates system state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

MODE="staged"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --live)   MODE="live";   shift ;;
        -h|--help)
            echo "Usage: verify_01_user_and_sudo.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. Check systemd attestation service is active (and enabled)
act="$("$HFT_SYSTEMCTL_CMD" is-active hft-verify-account.service 2>/dev/null || true)"
if [[ "$act" == "active" ]]; then
    pass_check "hft-verify-account.service is active"
else
    fail_check "hft-verify-account.service is not active (state=${act:-unknown})"
fi

# 2. Check attestation stamp file ownership 0:0, mode 644, boot_id match
ATTEST_FILE="${HFT_RUN_DIR}/layer1_01.verified"
CUR_BOOT_ID="$(current_boot_id || true)"

if [[ -f "$ATTEST_FILE" ]]; then
    ug="$(stat_ug "$ATTEST_FILE" || true)"
    mode="$(stat_mode "$ATTEST_FILE" || true)"
    if [[ "$ug" == "0:0" && ( "$mode" == "644" || "$mode" == "0644" ) ]]; then
        pass_check "Attestation file $ATTEST_FILE has owner=0:0 mode=$mode"
    else
        fail_check "Attestation file $ATTEST_FILE has invalid owner/mode (owner=${ug:-?} mode=${mode:-?}, expected 0:0 644)"
    fi

    att_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$ATTEST_FILE")"
    att_uid="$(awk -F= '$1=="hft_uid"{print $2; exit}' "$ATTEST_FILE")"
    att_fp="$(awk -F= '$1=="pubkey_fp"{print $2; exit}' "$ATTEST_FILE")"
    att_sha="$(awk -F= '$1=="sudoers_sha256"{print $2; exit}' "$ATTEST_FILE")"

    if [[ -n "$CUR_BOOT_ID" && "$att_boot" == "$CUR_BOOT_ID" ]]; then
        pass_check "Attestation boot_id matches current boot_id"
    else
        fail_check "Attestation boot_id mismatch (attested='${att_boot:-}' current='${CUR_BOOT_ID:-}')"
    fi
else
    fail_check "Missing attestation file: $ATTEST_FILE"
    att_uid=""
    att_fp=""
    att_sha=""
fi

# 3. Check user 'hft', uid match, sudo group membership
LIVE_UID="$("$HFT_ID_CMD" -u hft 2>/dev/null || true)"
if [[ -n "$LIVE_UID" && -n "$att_uid" && "$LIVE_UID" == "$att_uid" ]]; then
    pass_check "User hft UID matches attestation ($LIVE_UID)"
else
    fail_check "User hft UID check failed (live='${LIVE_UID:-missing}' attested='${att_uid:-}')"
fi

HFT_GROUPS=" $("$HFT_ID_CMD" -nG hft 2>/dev/null || true) "
if [[ "$HFT_GROUPS" == *" sudo "* ]]; then
    pass_check "User hft is in sudo group"
else
    fail_check "User hft is not in sudo group (groups: ${HFT_GROUPS})"
fi

# 4. Check authorized_keys live fingerprint matches attestation (pure read-only)
hft_entry="$("$HFT_GETENT_CMD" passwd hft 2>/dev/null || true)"
if [[ -n "$hft_entry" ]]; then
    hft_home="$(printf '%s\n' "$hft_entry" | awk -F: '{print $6}')"
    if [[ -n "$HFT_ROOT" && "$hft_home" != "${HFT_ROOT}"* ]]; then
        hft_home="${HFT_ROOT}${hft_home}"
    fi
else
    hft_home="${HFT_ROOT}/home/hft"
fi
AUTH_KEYS="${hft_home}/.ssh/authorized_keys"
if [[ -r "$AUTH_KEYS" ]]; then
    if grep -q "Please login as the user" "$AUTH_KEYS"; then
        fail_check "Cloud-init refusal line found in $AUTH_KEYS"
    fi
    LIVE_FP="$(compute_ssh_keyfile_fp "$AUTH_KEYS" || true)"
    if [[ -n "$LIVE_FP" && -n "$att_fp" && "$LIVE_FP" == "$att_fp" ]]; then
        pass_check "Live authorized_keys fingerprint matches attestation"
    else
        fail_check "authorized_keys fingerprint mismatch (live='${LIVE_FP:-}' attested='${att_fp:-}')"
    fi
else
    fail_check "Cannot read $AUTH_KEYS"
fi

# 5. Check Linger=yes (and in --live mode, /run/user/<uid>/systemd active)
LINGER_VAL="$("$HFT_LOGINCTL_CMD" show-user hft -p Linger --value 2>/dev/null || true)"
if [[ "$LINGER_VAL" == "yes" ]]; then
    pass_check "loginctl Linger=yes for hft"
else
    fail_check "Linger is not enabled for hft (got '${LINGER_VAL:-unknown}')"
fi

if [[ "$MODE" == "live" && -n "$LIVE_UID" ]]; then
    USER_SD_DIR="${HFT_ROOT}/run/user/${LIVE_UID}/systemd"
    if [[ -d "$USER_SD_DIR" ]]; then
        pass_check "Live user systemd runtime dir exists: $USER_SD_DIR"
    else
        fail_check "Live user systemd runtime dir missing: $USER_SD_DIR"
    fi
fi

# 6. Check /etc/hft exists
if [[ -d "${HFT_ROOT}/etc/hft" ]]; then
    pass_check "Directory ${HFT_ROOT}/etc/hft exists"
else
    fail_check "Directory ${HFT_ROOT}/etc/hft missing"
fi

# 7. When effective root, directly inspect sudoers file + visudo -c + sudo -l -U hft
if is_effective_root; then
    SUDOERS_FILE="${HFT_ROOT}/etc/sudoers.d/90-hft-nopasswd"
    if [[ -f "$SUDOERS_FILE" ]]; then
        s_ug="$(stat_ug "$SUDOERS_FILE" || true)"
        s_mode="$(stat_mode "$SUDOERS_FILE" || true)"
        s_sha="$(sha256_file "$SUDOERS_FILE" || true)"
        if [[ "$s_ug" == "0:0" && ( "$s_mode" == "440" || "$s_mode" == "0440" ) ]]; then
            pass_check "Direct root check: $SUDOERS_FILE is 0:0 mode $s_mode"
        else
            fail_check "Direct root check: $SUDOERS_FILE owner/mode invalid (owner=${s_ug:-?} mode=${s_mode:-?})"
        fi
        if [[ -n "$att_sha" && "$s_sha" == "$att_sha" ]]; then
            pass_check "Direct root check: sudoers sha256 matches attestation"
        else
            fail_check "Direct root check: sudoers sha256 drift (live='${s_sha:-}' attested='${att_sha:-}')"
        fi
    else
        fail_check "Direct root check: missing $SUDOERS_FILE"
    fi

    if "$HFT_VISUDO_CMD" -c >/dev/null 2>&1; then
        pass_check "Direct root check: visudo -c passed"
    else
        fail_check "Direct root check: visudo -c failed"
    fi

    sudo_bin="${HFT_SUDO_CMD:-sudo}"
    if "$sudo_bin" -l -U hft 2>&1 | grep -Eq 'NOPASSWD:[[:space:]]*ALL'; then
        pass_check "Direct root check: sudo -l -U hft confirms NOPASSWD:ALL"
    else
        fail_check "Direct root check: sudo -l -U hft does not confirm NOPASSWD:ALL"
    fi
fi

if (( FAIL > 0 )); then
    log_error "verify_01_user_and_sudo (${MODE}): ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_01_user_and_sudo (${MODE}): ALL CHECKS PASSED."
