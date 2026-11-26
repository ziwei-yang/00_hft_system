#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 03 (GRUB CPU isolation).
# Supports --staged (grub-script-check + next-boot entry) and --live (reboot gate + /proc/cmdline + sysfs isolated).
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
            echo "Usage: verify_03_grub_cpu_isolation.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

GRUB_FILE="${HFT_GRUB_FILE:-${HFT_ROOT}/etc/default/grub}"
GRUB_D_DIR="${HFT_GRUB_D_DIR:-${GRUB_FILE}.d}"
GRUB_CFG="${HFT_GRUB_CFG:-${HFT_ROOT}/boot/grub/grub.cfg}"
GRUB_ENV="${HFT_GRUB_ENV:-${HFT_ROOT}/boot/grub/grubenv}"
DROPIN_NAME="99-hft-isolation.cfg"
DROPIN_PATH="${GRUB_D_DIR}/${DROPIN_NAME}"
STAGED_STATE="${HFT_STATE_DIR}/grub_staged.state"

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. Drop-in presence, POSIX sh syntax, no post-99 override
if [[ -r "$DROPIN_PATH" ]]; then
    if /bin/sh -n "$DROPIN_PATH" 2>/dev/null; then
        pass_check "GRUB drop-in $DROPIN_PATH exists and passes /bin/sh -n"
    else
        fail_check "GRUB drop-in $DROPIN_PATH failed /bin/sh -n"
    fi
else
    fail_check "Missing GRUB drop-in: $DROPIN_PATH"
fi

if [[ -d "$GRUB_D_DIR" ]]; then
    shopt -s nullglob
    for cfg in "$GRUB_D_DIR"/*.cfg; do
        cfg_base="$(basename "$cfg")"
        if [[ "$cfg_base" > "$DROPIN_NAME" ]]; then
            if grep -Eq '^[[:space:]]*(GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX)=' "$cfg"; then
                fail_check "Later grub.d override $cfg modifies GRUB_CMDLINE_LINUX*"
            fi
        fi
    done
    shopt -u nullglob
fi

# Extract expected_isolated & expected_hft_params from drop-in comments or staged state
EXPECTED_ISOLATED=""
EXPECTED_HFT_PARAMS=""
STAGED_BOOT_ID=""

if [[ -r "$STAGED_STATE" ]]; then
    STAGED_BOOT_ID="$(awk -F= '$1=="staged_boot_id"{sub(/^staged_boot_id=/,""); print; exit}' "$STAGED_STATE")"
    EXPECTED_ISOLATED="$(awk -F= '$1=="expected_isolated"{sub(/^expected_isolated=/,""); print; exit}' "$STAGED_STATE")"
    EXPECTED_HFT_PARAMS="$(awk -F= '$1=="expected_hft_params"{sub(/^expected_hft_params=/,""); print; exit}' "$STAGED_STATE")"
fi
if [[ -z "$EXPECTED_ISOLATED" && -r "$DROPIN_PATH" ]]; then
    EXPECTED_ISOLATED="$(awk -F': ' '/^# Expected isolated CPUs: /{print $2; exit}' "$DROPIN_PATH")"
fi
if [[ -z "$EXPECTED_HFT_PARAMS" && -r "$DROPIN_PATH" ]]; then
    EXPECTED_HFT_PARAMS="$(awk -F': ' '/^# Expected HFT params: /{print $2; exit}' "$DROPIN_PATH")"
fi

if [[ -z "$EXPECTED_ISOLATED" || -z "$EXPECTED_HFT_PARAMS" ]]; then
    fail_check "Cannot determine expected isolated CPUs / HFT params from $DROPIN_PATH or $STAGED_STATE"
fi

# 2. grub-script-check + unique next-boot non-recovery entry check
if [[ -r "$GRUB_CFG" ]]; then
    if "$HFT_GRUB_SCRIPT_CHECK_CMD" "$GRUB_CFG" >/dev/null 2>&1; then
        pass_check "grub-script-check passed on $GRUB_CFG"
    else
        fail_check "grub-script-check failed on $GRUB_CFG"
    fi

    NEXT_LINUX_ARGS="$(grub_resolve_next_boot_linux_line "$GRUB_CFG" "$GRUB_ENV" 2>&1)" && next_ok=1 || next_ok=0
    if (( next_ok == 1 )); then
        pass_check "Resolved unique non-recovery next-boot GRUB entry"
        # Validate expected params and zero duplicate HFT keys
        declare -A kc=()
        for tok in $NEXT_LINUX_ARGS; do
            k="${tok%%=*}"
            case "$k" in
                isolcpus|nohz_full|rcu_nocbs|irqaffinity|intel_pstate|processor.max_cstate|idle)
                    kc["$k"]=$(( ${kc[$k]:-0} + 1 ))
                    ;;
            esac
        done
        params_ok=1
        for etok in $EXPECTED_HFT_PARAMS; do
            if [[ " $NEXT_LINUX_ARGS " != *" $etok "* ]]; then
                fail_check "Next-boot GRUB linux line missing '$etok'"
                params_ok=0
            fi
        done
        for k in "${!kc[@]}"; do
            if (( kc["$k"] > 1 )); then
                fail_check "Duplicate HFT key '$k' in next-boot GRUB linux line"
                params_ok=0
            fi
        done
        (( params_ok == 1 )) && pass_check "Next-boot GRUB linux line has exact HFT params with zero duplicates"
    else
        fail_check "Next-boot GRUB entry check failed: $NEXT_LINUX_ARGS"
    fi
else
    fail_check "Missing GRUB config: $GRUB_CFG"
fi

# 3. Live-mode checks: reboot gate + /proc/cmdline + /sys/devices/system/cpu/isolated
if [[ "$MODE" == "live" ]]; then
    CUR_BOOT_ID="$(current_boot_id || true)"
    if [[ -r "$STAGED_STATE" ]]; then
        if [[ -n "$CUR_BOOT_ID" && -n "$STAGED_BOOT_ID" && "$CUR_BOOT_ID" != "$STAGED_BOOT_ID" ]]; then
            pass_check "Reboot gate passed (current boot_id != staged_boot_id)"
        else
            fail_check "Reboot required: system has not rebooted since GRUB was staged (boot_id=${CUR_BOOT_ID:-?})"
        fi
    fi

    PROC_CMDLINE="${HFT_ROOT}/proc/cmdline"
    if [[ -r "$PROC_CMDLINE" ]]; then
        cmdline_val="$(cat "$PROC_CMDLINE")"
        cmd_ok=1
        for etok in $EXPECTED_HFT_PARAMS; do
            if [[ " $cmdline_val " != *" $etok "* ]]; then
                fail_check "/proc/cmdline missing expected param '$etok'"
                cmd_ok=0
            fi
        done
        (( cmd_ok == 1 )) && pass_check "/proc/cmdline contains all expected HFT parameters"
    else
        fail_check "Cannot read $PROC_CMDLINE"
    fi

    ISO_FILE="${HFT_ROOT}/sys/devices/system/cpu/isolated"
    if [[ -r "$ISO_FILE" ]]; then
        live_iso="$(tr -d '[:space:]' < "$ISO_FILE")"
        if [[ -n "$live_iso" && -n "$EXPECTED_ISOLATED" ]]; then
            norm_live="$(normalize_cpu_list "$live_iso" 2>/dev/null || echo "")"
            norm_exp="$(normalize_cpu_list "$EXPECTED_ISOLATED" 2>/dev/null || echo "")"
            if [[ -n "$norm_live" && "$norm_live" == "$norm_exp" ]]; then
                pass_check "/sys/devices/system/cpu/isolated matches expected ($norm_live)"
            else
                fail_check "Live isolated CPUs mismatch (live='${live_iso}' expected='${EXPECTED_ISOLATED}')"
            fi
        else
            fail_check "Live isolated CPUs empty (expected '${EXPECTED_ISOLATED}')"
        fi
    else
        fail_check "Cannot read $ISO_FILE"
    fi
fi

if (( FAIL > 0 )); then
    log_error "verify_03_grub_cpu_isolation (${MODE}): ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_03_grub_cpu_isolation (${MODE}): ALL CHECKS PASSED."
