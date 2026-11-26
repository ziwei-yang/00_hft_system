#!/usr/bin/env bash
# Layer 1 Step 04: Disable/mask irqbalance, install NIC coalescing tuning service,
# IRQ pinning service (with strict IRQD_AFFINITY_MANAGED check), and CPU performance governor service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_priv_ready

banner "Layer 1 Step 04: IRQ Pinning, NIC Coalescing, and CPU Performance"

# Prerequisite pure read-only verifiers
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"
run_verify_chain "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh"

txn_init "04_irq_nic_and_perf"

# 1. Stop, disable, and mask irqbalance
irqb_state="$(systemctl_state_pair irqbalance)"
txn_record_kv unit_state "irqbalance" "$irqb_state"
if [[ "${irqb_state#*:}" == "active" ]]; then
    run_priv "$HFT_SYSTEMCTL_CMD" stop irqbalance
fi
if [[ "${irqb_state%%:*}" != "masked" && "${irqb_state%%:*}" != "not-found" ]]; then
    run_priv "$HFT_SYSTEMCTL_CMD" disable irqbalance 2>/dev/null || true
    run_priv "$HFT_SYSTEMCTL_CMD" mask irqbalance
fi

# Record original NIC coalesce state in txn if default route iface exists
DEF_IFACE="$("$HFT_IP_CMD" route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
if [[ -n "$DEF_IFACE" && "$DEF_IFACE" != "lo" ]]; then
    orig_c="$("$HFT_ETHTOOL_CMD" -c "$DEF_IFACE" 2>/dev/null || true)"
    orig_ad="$(printf '%s\n' "$orig_c" | awk -F: '/Adaptive RX:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); split($2,a," "); print a[1]; exit}')"
    orig_rx="$(printf '%s\n' "$orig_c" | awk -F: '/^rx-usecs:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
    if [[ -n "$orig_ad" && -n "$orig_rx" ]]; then
        txn_record_kv coalesce "$DEF_IFACE" "${orig_ad}:${orig_rx}"
    fi
fi

# 2. Install /usr/local/sbin/hft-nic-tune.sh and hft-nic-tune.service
NIC_SCRIPT="${HFT_ROOT}/usr/local/sbin/hft-nic-tune.sh"
NIC_UNIT="${HFT_ROOT}/etc/systemd/system/hft-nic-tune.service"
txn_record_file "$NIC_SCRIPT"
txn_record_file "$NIC_UNIT"
txn_record_kv unit_state "hft-nic-tune.service" "$(systemctl_state_pair hft-nic-tune.service)"

atomic_write_priv "$NIC_SCRIPT" 0755 0:0 <<'EOF'
#!/usr/bin/env bash
# Boot-time NIC interrupt coalescing tuning (adaptive-rx off, rx-usecs 0).
set -euo pipefail

HFT_ROOT="${HFT_ROOT:-}"
while [[ -n "$HFT_ROOT" && "$HFT_ROOT" != "/" && "${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="${HFT_ROOT%/}"
done
[[ "$HFT_ROOT" == "/" ]] && HFT_ROOT=""

HFT_RUN_DIR="${HFT_RUN_DIR:-${HFT_ROOT}/run/hft-bootstrap}"
HFT_STATE_DIR="${HFT_STATE_DIR:-${HFT_ROOT}/var/lib/hft-bootstrap}"
HFT_IP_CMD="${HFT_IP_CMD:-ip}"
HFT_ETHTOOL_CMD="${HFT_ETHTOOL_CMD:-ethtool}"
HFT_CHMOD_CMD="${HFT_CHMOD_CMD:-chmod}"
HFT_CHOWN_CMD="${HFT_CHOWN_CMD:-chown}"

iface="$("$HFT_IP_CMD" route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [[ -z "$iface" || "$iface" == "lo" ]]; then
    echo "Error: cannot find default-route non-loopback network interface" >&2
    exit 1
fi

boot_id="$(tr -d '[:space:]' < "${HFT_ROOT}/proc/sys/kernel/random/boot_id")"
[[ -n "$boot_id" ]] || { echo "Error: empty boot_id" >&2; exit 1; }

# Save original coalesce settings once for rollback visibility
mkdir -p "$HFT_STATE_DIR"
orig_file="${HFT_STATE_DIR}/nic_coalesce.orig"
if [[ ! -f "$orig_file" ]]; then
    "$HFT_ETHTOOL_CMD" -c "$iface" > "$orig_file" 2>/dev/null || true
fi

status="ok"
adaptive_rx="off"
rx_usecs="0"

set +e
et_out="$("$HFT_ETHTOOL_CMD" -C "$iface" adaptive-rx off rx-usecs 0 2>&1)"
et_rc=$?
set -e

if (( et_rc != 0 )); then
    if printf '%s\n' "$et_out" | grep -Eqi 'Operation not supported|not supported'; then
        status="unsupported_skip"
        adaptive_rx="unsupported"
        rx_usecs="unsupported"
    else
        echo "Error: ethtool -C $iface failed (rc=$et_rc): $et_out" >&2
        exit 1
    fi
else
    # Mandatory live read-back verification
    rb="$("$HFT_ETHTOOL_CMD" -c "$iface" 2>&1)"
    rb_ad="$(printf '%s\n' "$rb" | awk -F: '/Adaptive RX:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); split($2,a," "); print a[1]; exit}')"
    rb_rx="$(printf '%s\n' "$rb" | awk -F: '/^rx-usecs:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
    if [[ "$rb_ad" != "off" || "$rb_rx" != "0" ]]; then
        echo "Error: ethtool -c read-back mismatch on $iface (adaptive-rx='${rb_ad}', rx-usecs='${rb_rx}')" >&2
        exit 1
    fi
    adaptive_rx="$rb_ad"
    rx_usecs="$rb_rx"
fi

mkdir -p "$HFT_RUN_DIR"
out_file="${HFT_RUN_DIR}/nic_tune.ok"
stage="${out_file}.tmp.$$"
cat > "$stage" <<STAMP
boot_id=${boot_id}
iface=${iface}
status=${status}
adaptive_rx=${adaptive_rx}
rx_usecs=${rx_usecs}
STAMP
"$HFT_CHMOD_CMD" 0644 "$stage"
"$HFT_CHOWN_CMD" 0:0 "$stage"
mv -f "$stage" "$out_file"
EOF

atomic_write_priv "$NIC_UNIT" 0644 0:0 <<'EOF'
[Unit]
Description=HFT NIC Interrupt Coalescing Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hft-nic-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 3. Install /usr/local/sbin/hft-pin-irqs.sh and hft-pin-irqs.service
IRQ_SCRIPT="${HFT_ROOT}/usr/local/sbin/hft-pin-irqs.sh"
IRQ_UNIT="${HFT_ROOT}/etc/systemd/system/hft-pin-irqs.service"
txn_record_file "$IRQ_SCRIPT"
txn_record_file "$IRQ_UNIT"
txn_record_kv unit_state "hft-pin-irqs.service" "$(systemctl_state_pair hft-pin-irqs.service)"

# Record current IRQ affinities on isolated CPUs in txn before pinning
ISO_SYS="${HFT_ROOT}/sys/devices/system/cpu/isolated"
if [[ -r "$ISO_SYS" ]]; then
    cur_iso="$(tr -d '[:space:]' < "$ISO_SYS")"
    if [[ -n "$cur_iso" ]]; then
        shopt -s nullglob
        for irq_d in "${HFT_ROOT}"/proc/irq/[0-9]*; do
            [[ -f "$irq_d/smp_affinity_list" ]] || continue
            old_aff="$(tr -d '[:space:]' < "$irq_d/smp_affinity_list" 2>/dev/null || true)"
            [[ -n "$old_aff" ]] && txn_record_kv irq "$irq_d/smp_affinity_list" "$old_aff"
        done
        shopt -u nullglob
    fi
fi

atomic_write_priv "$IRQ_SCRIPT" 0755 0:0 <<'EOF'
#!/usr/bin/env bash
# Boot-time IRQ pinning to CPU 0 with strict IRQD_AFFINITY_MANAGED verification.
set -euo pipefail

HFT_ROOT="${HFT_ROOT:-}"
while [[ -n "$HFT_ROOT" && "$HFT_ROOT" != "/" && "${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="${HFT_ROOT%/}"
done
[[ "$HFT_ROOT" == "/" ]] && HFT_ROOT=""

HFT_RUN_DIR="${HFT_RUN_DIR:-${HFT_ROOT}/run/hft-bootstrap}"
HFT_CHMOD_CMD="${HFT_CHMOD_CMD:-chmod}"
HFT_CHOWN_CMD="${HFT_CHOWN_CMD:-chown}"

expand_list() {
    local raw="$1"
    local -a parts=()
    IFS=',' read -ra parts <<< "$raw"
    local p a b i
    for p in "${parts[@]}"; do
        if [[ "$p" == *-* ]]; then
            a="${p%%-*}"
            b="${p#*-}"
            for (( i = 10#$a; i <= 10#$b; i++ )); do
                printf '%d\n' "$i"
            done
        elif [[ "$p" =~ ^[0-9]+$ ]]; then
            printf '%d\n' "$((10#$p))"
        fi
    done
}

boot_id="$(tr -d '[:space:]' < "${HFT_ROOT}/proc/sys/kernel/random/boot_id")"
[[ -n "$boot_id" ]] || { echo "Error: empty boot_id" >&2; exit 1; }

iso_file="${HFT_ROOT}/sys/devices/system/cpu/isolated"
isolated=""
if [[ -r "$iso_file" ]]; then
    isolated="$(tr -d '[:space:]' < "$iso_file")"
fi

declare -A ISO_SET=()
if [[ -n "$isolated" ]]; then
    while IFS= read -r c; do
        [[ -n "$c" ]] && ISO_SET["$c"]=1
    done < <(expand_list "$isolated")
fi

overlaps_isolated() {
    local list_val="$1"
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        if [[ -n "${ISO_SET[$c]+x}" ]]; then
            return 0
        fi
    done < <(expand_list "$list_val")
    return 1
}

declare -a MANAGED_LIST=()
if (( ${#ISO_SET[@]} > 0 )); then
    shopt -s nullglob
    for irq_dir in "${HFT_ROOT}"/proc/irq/[0-9]*; do
        [[ -d "$irq_dir" ]] || continue
        irq_num="$(basename "$irq_dir")"
        [[ "$irq_num" =~ ^[0-9]+$ ]] || continue

        eff_file="${irq_dir}/effective_affinity_list"
        smp_file="${irq_dir}/smp_affinity_list"
        check_file="$eff_file"
        [[ -r "$check_file" ]] || check_file="$smp_file"
        [[ -r "$check_file" ]] || continue

        cur_aff="$(tr -d '[:space:]' < "$check_file" 2>/dev/null || true)"
        [[ -n "$cur_aff" ]] || continue
        if ! overlaps_isolated "$cur_aff"; then
            continue
        fi

        # Attempt to pin movable IRQ to CPU 0
        if [[ -w "$smp_file" ]]; then
            printf '0\n' > "$smp_file" 2>/dev/null || true
            # If running in a test mock without kernel updating effective_affinity_list,
            # allow mock hook or check effective_affinity_list directly.
        fi

        # Re-read effective affinity
        after_aff="$(tr -d '[:space:]' < "$check_file" 2>/dev/null || true)"
        if overlaps_isolated "$after_aff"; then
            # Must be strictly verified as IRQD_AFFINITY_MANAGED (exact whole word!)
            dbg_file="${HFT_ROOT}/sys/kernel/debug/irq/irqs/${irq_num}"
            if [[ -r "$dbg_file" ]] && grep -Eq '(^|[^A-Za-z0-9_])IRQD_AFFINITY_MANAGED([^A-Za-z0-9_]|$)' "$dbg_file"; then
                MANAGED_LIST+=("$irq_num")
            else
                echo "Error: IRQ ${irq_num} remains on isolated CPU(s) (${after_aff}) without exact IRQD_AFFINITY_MANAGED flag in ${dbg_file}" >&2
                exit 1
            fi
        fi
    done
    shopt -u nullglob
fi

managed_csv=""
if (( ${#MANAGED_LIST[@]} > 0 )); then
    managed_csv="$(printf '%s\n' "${MANAGED_LIST[@]}" | sort -nu | paste -sd ',' -)"
fi

mkdir -p "$HFT_RUN_DIR"
out_file="${HFT_RUN_DIR}/pin_irqs.ok"
stage="${out_file}.tmp.$$"
cat > "$stage" <<STAMP
boot_id=${boot_id}
isolated=${isolated}
managed_irqs=${managed_csv}
STAMP
"$HFT_CHMOD_CMD" 0644 "$stage"
"$HFT_CHOWN_CMD" 0:0 "$stage"
mv -f "$stage" "$out_file"
EOF

atomic_write_priv "$IRQ_UNIT" 0644 0:0 <<'EOF'
[Unit]
Description=HFT IRQ Pinning to CPU 0
After=network-online.target hft-nic-tune.service
Requires=hft-nic-tune.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hft-pin-irqs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 4. Optional CPU performance governor service when cpufreq policies exist
shopt -s nullglob
CPUFREQ_POLICIES=("${HFT_ROOT}"/sys/devices/system/cpu/cpufreq/policy*)
shopt -u nullglob

HAS_CPUFREQ=0
if (( ${#CPUFREQ_POLICIES[@]} > 0 )); then
    HAS_CPUFREQ=1
    for pdir in "${CPUFREQ_POLICIES[@]}"; do
        gov_f="${pdir}/scaling_governor"
        if [[ -r "$gov_f" ]]; then
            old_gov="$(tr -d '[:space:]' < "$gov_f")"
            txn_record_kv governor "$gov_f" "$old_gov"
        fi
    done

    PERF_SCRIPT="${HFT_ROOT}/usr/local/sbin/hft-cpu-performance.sh"
    PERF_UNIT="${HFT_ROOT}/etc/systemd/system/hft-cpu-performance.service"
    txn_record_file "$PERF_SCRIPT"
    txn_record_file "$PERF_UNIT"
    txn_record_kv unit_state "hft-cpu-performance.service" "$(systemctl_state_pair hft-cpu-performance.service)"

    atomic_write_priv "$PERF_SCRIPT" 0755 0:0 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HFT_ROOT="${HFT_ROOT:-}"
while [[ -n "$HFT_ROOT" && "$HFT_ROOT" != "/" && "${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="${HFT_ROOT%/}"
done
[[ "$HFT_ROOT" == "/" ]] && HFT_ROOT=""

shopt -s nullglob
for gov in "${HFT_ROOT}"/sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    printf 'performance\n' > "$gov"
done
shopt -u nullglob
EOF

    atomic_write_priv "$PERF_UNIT" 0644 0:0 <<'EOF'
[Unit]
Description=HFT CPU Performance Governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hft-cpu-performance.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

run_priv "$HFT_SYSTEMCTL_CMD" daemon-reload
run_priv "$HFT_SYSTEMCTL_CMD" enable hft-nic-tune.service
run_priv "$HFT_SYSTEMCTL_CMD" enable hft-pin-irqs.service
run_priv "$NIC_SCRIPT"
run_priv "$HFT_SYSTEMCTL_CMD" start hft-nic-tune.service
run_priv "$IRQ_SCRIPT"
run_priv "$HFT_SYSTEMCTL_CMD" start hft-pin-irqs.service

if (( HAS_CPUFREQ == 1 )); then
    run_priv "$HFT_SYSTEMCTL_CMD" enable hft-cpu-performance.service
    run_priv "$PERF_SCRIPT"
    run_priv "$HFT_SYSTEMCTL_CMD" start hft-cpu-performance.service
fi

# Self-verify
bash "${SCRIPT_DIR}/verify_04_irq_nic_and_perf.sh" --staged
log_success "Layer 1 Step 04 complete."
