#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 04 (irqbalance, NIC tuning, IRQ pinning, cpufreq).
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
            echo "Usage: verify_04_irq_nic_and_perf.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

# 1. irqbalance stopped & masked (or not-found)
irqb_act="$("$HFT_SYSTEMCTL_CMD" is-active irqbalance 2>/dev/null || true)"
[[ -z "$irqb_act" ]] && irqb_act="inactive"
irqb_en="$("$HFT_SYSTEMCTL_CMD" is-enabled irqbalance 2>/dev/null || true)"
[[ -z "$irqb_en" ]] && irqb_en="not-found"
if [[ "$irqb_act" != "active" && ( "$irqb_en" == "masked" || "$irqb_en" == "not-found" ) ]]; then
    pass_check "irqbalance inactive and masked/not-found (active=$irqb_act enabled=$irqb_en)"
else
    fail_check "irqbalance not disabled/masked (active=$irqb_act enabled=$irqb_en)"
fi

# 2. Units enabled
for u in hft-nic-tune.service hft-pin-irqs.service; do
    en="$("$HFT_SYSTEMCTL_CMD" is-enabled "$u" 2>/dev/null || true)"
    if [[ "$en" == "enabled" ]]; then
        pass_check "$u is enabled"
    else
        fail_check "$u is not enabled (state=${en:-unknown})"
    fi
done

shopt -s nullglob
CPUFREQ_POLICIES=("${HFT_ROOT}"/sys/devices/system/cpu/cpufreq/policy*)
shopt -u nullglob
HAS_CPUFREQ=0
if (( ${#CPUFREQ_POLICIES[@]} > 0 )); then
    HAS_CPUFREQ=1
    en="$("$HFT_SYSTEMCTL_CMD" is-enabled hft-cpu-performance.service 2>/dev/null || true)"
    if [[ "$en" == "enabled" ]]; then
        pass_check "hft-cpu-performance.service is enabled"
    else
        fail_check "hft-cpu-performance.service is not enabled (state=${en:-unknown})"
    fi
fi

# 3. Live checks
if [[ "$MODE" == "live" ]]; then
    CUR_BOOT_ID="$(current_boot_id || true)"

    for u in hft-nic-tune.service hft-pin-irqs.service; do
        act="$("$HFT_SYSTEMCTL_CMD" is-active "$u" 2>/dev/null || true)"
        if [[ "$act" == "active" ]]; then
            pass_check "$u is active"
        else
            fail_check "$u is not active (state=${act:-unknown})"
        fi
    done

    # Check nic_tune.ok + LIVE ethtool -c readback (anti-drift!)
    NIC_OK="${HFT_RUN_DIR}/nic_tune.ok"
    if [[ -r "$NIC_OK" ]]; then
        ug="$(stat_ug "$NIC_OK" || true)"
        mode="$(stat_mode "$NIC_OK" || true)"
        nic_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$NIC_OK")"
        nic_iface="$(awk -F= '$1=="iface"{print $2; exit}' "$NIC_OK")"
        nic_status="$(awk -F= '$1=="status"{print $2; exit}' "$NIC_OK")"

        if [[ "$ug" == "0:0" && ( "$mode" == "644" || "$mode" == "0644" ) && "$nic_boot" == "$CUR_BOOT_ID" ]]; then
            pass_check "nic_tune.ok valid (owner=0:0 mode=$mode boot_id matches)"
        else
            fail_check "nic_tune.ok invalid (owner=${ug:-?} mode=${mode:-?} boot='${nic_boot:-}' cur='${CUR_BOOT_ID:-}')"
        fi

        if [[ "$nic_status" == "ok" ]]; then
            live_c="$("$HFT_ETHTOOL_CMD" -c "$nic_iface" 2>&1 || true)"
            live_ad="$(printf '%s\n' "$live_c" | awk -F: '/Adaptive RX:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); split($2,a," "); print a[1]; exit}')"
            live_rx="$(printf '%s\n' "$live_c" | awk -F: '/^rx-usecs:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
            if [[ "$live_ad" == "off" && "$live_rx" == "0" ]]; then
                pass_check "Live ethtool -c $nic_iface confirmed adaptive-rx=off rx-usecs=0"
            else
                fail_check "Live ethtool -c $nic_iface drift detected (adaptive-rx='${live_ad:-?}', rx-usecs='${live_rx:-?}')"
            fi
        elif [[ "$nic_status" == "unsupported_skip" ]]; then
            pass_check "NIC $nic_iface coalescing marked unsupported_skip"
        else
            fail_check "Unknown status in nic_tune.ok: '${nic_status:-}'"
        fi
    else
        fail_check "Missing $NIC_OK"
    fi

    # Check pin_irqs.ok + live /proc/irq/*/effective_affinity_list scan
    IRQ_OK="${HFT_RUN_DIR}/pin_irqs.ok"
    declare -A ALLOWED_MANAGED=()
    if [[ -r "$IRQ_OK" ]]; then
        ug="$(stat_ug "$IRQ_OK" || true)"
        mode="$(stat_mode "$IRQ_OK" || true)"
        irq_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$IRQ_OK")"
        managed_csv="$(awk -F= '$1=="managed_irqs"{print $2; exit}' "$IRQ_OK")"

        if [[ "$ug" == "0:0" && ( "$mode" == "644" || "$mode" == "0644" ) && "$irq_boot" == "$CUR_BOOT_ID" ]]; then
            pass_check "pin_irqs.ok valid (owner=0:0 mode=$mode boot_id matches)"
        else
            fail_check "pin_irqs.ok invalid (owner=${ug:-?} mode=${mode:-?} boot='${irq_boot:-}' cur='${CUR_BOOT_ID:-}')"
        fi

        if [[ -n "$managed_csv" ]]; then
            IFS=',' read -ra _m_arr <<< "$managed_csv"
            for m in "${_m_arr[@]}"; do
                [[ -n "$m" ]] && ALLOWED_MANAGED["$m"]=1
            done
        fi
    else
        fail_check "Missing $IRQ_OK"
    fi

    ISO_FILE="${HFT_ROOT}/sys/devices/system/cpu/isolated"
    if [[ -r "$ISO_FILE" ]]; then
        iso_raw="$(tr -d '[:space:]' < "$ISO_FILE")"
        if [[ -n "$iso_raw" ]]; then
            declare -A ISO_SET=()
            while IFS= read -r c; do
                [[ -n "$c" ]] && ISO_SET["$c"]=1
            done < <(parse_cpu_list "$iso_raw")

            bad_irqs=0
            shopt -s nullglob
            for irq_dir in "${HFT_ROOT}"/proc/irq/[0-9]*; do
                [[ -d "$irq_dir" ]] || continue
                irq_num="$(basename "$irq_dir")"
                [[ "$irq_num" =~ ^[0-9]+$ ]] || continue
                eff_f="${irq_dir}/effective_affinity_list"
                [[ -r "$eff_f" ]] || eff_f="${irq_dir}/smp_affinity_list"
                [[ -r "$eff_f" ]] || continue
                aff="$(tr -d '[:space:]' < "$eff_f" 2>/dev/null || true)"
                [[ -n "$aff" ]] || continue

                overlap=0
                while IFS= read -r c; do
                    [[ -n "$c" ]] || continue
                    if [[ -n "${ISO_SET[$c]+x}" ]]; then
                        overlap=1
                        break
                    fi
                done < <(parse_cpu_list "$aff" 2>/dev/null || true)

                if (( overlap == 1 )); then
                    if [[ -z "${ALLOWED_MANAGED[$irq_num]+x}" ]]; then
                        fail_check "Live IRQ $irq_num on isolated CPU(s) ($aff) is NOT in current-boot managed allowlist"
                        bad_irqs=$((bad_irqs + 1))
                    elif is_effective_root; then
                        dbg_f="${HFT_ROOT}/sys/kernel/debug/irq/irqs/${irq_num}"
                        if [[ ! -r "$dbg_f" ]] || ! grep -Eq '(^|[^A-Za-z0-9_])IRQD_AFFINITY_MANAGED([^A-Za-z0-9_]|$)' "$dbg_f"; then
                            fail_check "Live IRQ $irq_num lacks exact IRQD_AFFINITY_MANAGED flag in $dbg_f"
                            bad_irqs=$((bad_irqs + 1))
                        fi
                    fi
                fi
            done
            shopt -u nullglob
            if (( bad_irqs == 0 )); then
                pass_check "Live /proc/irq/*/effective_affinity_list clean on isolated CPUs ($iso_raw)"
            fi
        fi
    fi

    # Check cpufreq performance governor live
    if (( HAS_CPUFREQ == 1 )); then
        act="$("$HFT_SYSTEMCTL_CMD" is-active hft-cpu-performance.service 2>/dev/null || true)"
        if [[ "$act" == "active" ]]; then
            pass_check "hft-cpu-performance.service is active"
        else
            fail_check "hft-cpu-performance.service is not active (state=${act:-unknown})"
        fi

        gov_bad=0
        for pdir in "${CPUFREQ_POLICIES[@]}"; do
            gov_f="${pdir}/scaling_governor"
            if [[ -r "$gov_f" ]]; then
                g="$(tr -d '[:space:]' < "$gov_f")"
                if [[ "$g" != "performance" ]]; then
                    fail_check "Governor drift at $gov_f: got '$g' (expected performance)"
                    gov_bad=$((gov_bad + 1))
                fi
            fi
        done
        (( gov_bad == 0 )) && pass_check "All cpufreq policies set to performance"
    fi
fi

if (( FAIL > 0 )); then
    log_error "verify_04_irq_nic_and_perf (${MODE}): ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_04_irq_nic_and_perf (${MODE}): ALL CHECKS PASSED."
