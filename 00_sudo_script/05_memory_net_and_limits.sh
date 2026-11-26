#!/usr/bin/env bash
# Layer 1 Step 05: Hugepages (>=512 x 2MB, never downsize), /dev/hugepages mount drop-in
# + permissions service, /dev/shm THP huge=within_size, low-latency sysctls, and hft-only limits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_priv_ready

banner "Layer 1 Step 05: Hugepages, /dev/shm THP, Network Sysctls, and hft Limits"

# Prerequisite pure read-only verifiers
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"
run_verify_chain "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_04_irq_nic_and_perf.sh"

# 1. Fail-closed RAM & Hugepagesize checks BEFORE making any changes
MEMINFO="${HFT_ROOT}/proc/meminfo"
[[ -r "$MEMINFO" ]] || die "Cannot read $MEMINFO"

MEM_TOTAL_KB="$(awk '/^MemTotal:/{print $2; exit}' "$MEMINFO")"
if [[ ! "$MEM_TOTAL_KB" =~ ^[0-9]+$ ]] || (( MEM_TOTAL_KB < 4194304 )); then
    die "Total memory (${MEM_TOTAL_KB:-0} kB) is below 4 GiB (4194304 kB); refusing to allocate 1 GiB hugepage pool."
fi

HP_SIZE_KB="$(awk '/^Hugepagesize:/{print $2; exit}' "$MEMINFO")"
if [[ "$HP_SIZE_KB" != "2048" ]]; then
    die "Expected Hugepagesize == 2048 kB (got '${HP_SIZE_KB:-unknown} kB')."
fi

# 2. Compute TARGET_HP = max(512, current live nr_hugepages, existing persistent vm.nr_hugepages)
TARGET_HP=512
LIVE_HP_FILE="${HFT_ROOT}/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
if [[ -r "$LIVE_HP_FILE" ]]; then
    cur_hp="$(tr -d '[:space:]' < "$LIVE_HP_FILE")"
    if [[ "$cur_hp" =~ ^[0-9]+$ ]] && (( cur_hp > TARGET_HP )); then
        TARGET_HP="$cur_hp"
    fi
fi

check_sysctl_hp_file() {
    local f="$1"
    [[ -r "$f" ]] || return 0
    local v
    while IFS= read -r v; do
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v > TARGET_HP )); then
            TARGET_HP="$v"
        fi
    done < <(awk -F= '/^[[:space:]]*vm\.nr_hugepages[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$f")
}

check_sysctl_hp_file "${HFT_ROOT}/etc/sysctl.conf"
if [[ -d "${HFT_ROOT}/etc/sysctl.d" ]]; then
    shopt -s nullglob
    for sf in "${HFT_ROOT}"/etc/sysctl.d/*.conf; do
        check_sysctl_hp_file "$sf"
    done
    shopt -u nullglob
fi
log_info "Computed target 2MB hugepages (never downsize): ${TARGET_HP}"

# 3. Resolve numeric HFT_UID / HFT_GID
HFT_UID="$("$HFT_ID_CMD" -u hft)"
HFT_GID="$("$HFT_ID_CMD" -g hft)"
[[ "$HFT_UID" =~ ^[0-9]+$ && "$HFT_GID" =~ ^[0-9]+$ ]] || die "Failed to resolve numeric UID/GID for user hft"

hft_entry="$("$HFT_GETENT_CMD" passwd hft 2>/dev/null || true)"
if [[ -n "$hft_entry" ]]; then
    HFT_HOME="$(printf '%s\n' "$hft_entry" | awk -F: '{print $6}')"
    if [[ -n "$HFT_ROOT" && "$HFT_HOME" != "${HFT_ROOT}"* ]]; then
        HFT_HOME="${HFT_ROOT}${HFT_HOME}"
    fi
else
    HFT_HOME="${HFT_ROOT}/home/hft"
fi

txn_init "05_memory_net_and_limits"

# 4. Write /etc/sysctl.d/99-hft-lowlatency.conf (NO deprecated tcp_low_latency)
SYSCTL_FILE="${HFT_ROOT}/etc/sysctl.d/99-hft-lowlatency.conf"
txn_record_file "$SYSCTL_FILE"

record_old_sysctl() {
    local key="$1"
    local p="${HFT_ROOT}/proc/sys/${key//./\/}"
    if [[ -r "$p" ]]; then
        local old_v
        old_v="$(tr '\t' ' ' < "$p" | sed -E 's/[[:space:]]+/ /g; s/^ | $//g')"
        txn_record_kv sysctl "$key" "$old_v"
    fi
}

for k in vm.nr_hugepages vm.swappiness net.core.rmem_max net.core.wmem_max \
         net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.netdev_max_backlog \
         net.core.busy_read net.core.busy_poll; do
    record_old_sysctl "$k"
done

{
    cat <<EOF
# Managed by 05_memory_net_and_limits.sh
vm.nr_hugepages = ${TARGET_HP}
vm.swappiness = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
EOF
    if [[ -e "${HFT_ROOT}/proc/sys/net/core/busy_read" ]]; then
        printf 'net.core.busy_read = 50\n'
    fi
    if [[ -e "${HFT_ROOT}/proc/sys/net/core/busy_poll" ]]; then
        printf 'net.core.busy_poll = 50\n'
    fi
} | atomic_write_priv "$SYSCTL_FILE" 0644 0:0

log_info "Applying sysctl settings from $SYSCTL_FILE..."
run_priv "$HFT_SYSCTL_CMD" -p "$SYSCTL_FILE" >/dev/null

# 5. Valid [Mount] drop-in for dev-hugepages.mount (NO ExecStartPost=!)
HP_MOUNT_DROPIN="${HFT_ROOT}/etc/systemd/system/dev-hugepages.mount.d/99-hft.conf"
txn_record_file "$HP_MOUNT_DROPIN"
atomic_write_priv "$HP_MOUNT_DROPIN" 0644 0:0 <<EOF
[Mount]
Options=nosuid,nodev,pagesize=2M,mode=0775,gid=${HFT_GID}
EOF

# 6. Install & enable hft-hugepages-perms.service + script, and fix /dev/hugepages permissions now
HP_PERMS_SCRIPT="${HFT_ROOT}/usr/local/sbin/hft-hugepages-perms.sh"
HP_PERMS_UNIT="${HFT_ROOT}/etc/systemd/system/hft-hugepages-perms.service"
txn_record_file "$HP_PERMS_SCRIPT"
txn_record_file "$HP_PERMS_UNIT"
txn_record_kv unit_state "hft-hugepages-perms.service" "$(systemctl_state_pair hft-hugepages-perms.service)"

atomic_write_priv "$HP_PERMS_SCRIPT" 0755 0:0 <<EOF
#!/usr/bin/env bash
set -euo pipefail
HFT_ROOT="\${HFT_ROOT:-}"
while [[ -n "\$HFT_ROOT" && "\$HFT_ROOT" != "/" && "\${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="\${HFT_ROOT%/}"
done
[[ "\$HFT_ROOT" == "/" ]] && HFT_ROOT=""

HFT_RUN_DIR="\${HFT_RUN_DIR:-\${HFT_ROOT}/run/hft-bootstrap}"
HFT_CHOWN_CMD="\${HFT_CHOWN_CMD:-chown}"
HFT_CHMOD_CMD="\${HFT_CHMOD_CMD:-chmod}"

HP_DIR="\${HFT_ROOT}/dev/hugepages"
[[ -d "\$HP_DIR" ]] || { echo "Error: missing \$HP_DIR" >&2; exit 1; }
"\$HFT_CHOWN_CMD" "0:${HFT_GID}" "\$HP_DIR"
"\$HFT_CHMOD_CMD" 0775 "\$HP_DIR"

boot_id="\$(tr -d '[:space:]' < "\${HFT_ROOT}/proc/sys/kernel/random/boot_id")"
mkdir -p "\$HFT_RUN_DIR"
out="\${HFT_RUN_DIR}/hugepages.ok"
stage="\${out}.tmp.\$\$"
cat > "\$stage" <<STAMP
boot_id=\${boot_id}
gid=${HFT_GID}
mode=0775
STAMP
"\$HFT_CHMOD_CMD" 0644 "\$stage"
"\$HFT_CHOWN_CMD" 0:0 "\$stage"
mv -f "\$stage" "\$out"
EOF

atomic_write_priv "$HP_PERMS_UNIT" 0644 0:0 <<'EOF'
[Unit]
Description=HFT /dev/hugepages Group Permissions and Boot Stamp
Requires=dev-hugepages.mount
After=dev-hugepages.mount

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hft-hugepages-perms.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run_priv "$HFT_SYSTEMCTL_CMD" daemon-reload
run_priv "$HFT_SYSTEMCTL_CMD" enable hft-hugepages-perms.service
run_priv "$HP_PERMS_SCRIPT"
run_priv "$HFT_SYSTEMCTL_CMD" start hft-hugepages-perms.service

# 7. /dev/shm THP huge=within_size (preserve existing /etc/fstab options!)
FSTAB="${HFT_ROOT}/etc/fstab"
txn_record_file "$FSTAB"

if [[ -f "$FSTAB" ]] && awk '$1 !~ /^#/ && $2 == "/dev/shm" {found=1} END{exit !found}' "$FSTAB"; then
    # Merge huge=within_size into existing /dev/shm fstab options while preserving all existing options
    new_fstab="$(awk '
        $1 !~ /^#/ && $2 == "/dev/shm" {
            if ($4 !~ /(^|,)huge=within_size(,|$)/) {
                $4 = $4 ",huge=within_size"
            }
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
            next
        }
        { print }
    ' "$FSTAB")"
    printf '%s\n' "$new_fstab" | atomic_write_priv "$FSTAB" 0644 0:0
else
    {
        [[ -f "$FSTAB" ]] && cat "$FSTAB"
        printf 'tmpfs\t/dev/shm\ttmpfs\tdefaults,huge=within_size\t0\t0\n'
    } | atomic_write_priv "$FSTAB" 0644 0:0
fi

# Remount /dev/shm if not already mounted with huge=within_size
shm_opts="$("$HFT_FINDMNT_CMD" -no OPTIONS /dev/shm 2>/dev/null || true)"
if [[ ",${shm_opts}," != *",huge=within_size,"* ]]; then
    log_info "Remounting /dev/shm with huge=within_size..."
    run_priv "$HFT_MOUNT_CMD" -o remount,huge=within_size /dev/shm
fi

# Set THP sysfs knobs + /etc/tmpfiles.d/hft-shm-thp.conf
for knob in \
    "${HFT_ROOT}/sys/kernel/mm/transparent_hugepage/shmem_enabled" \
    "${HFT_ROOT}/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled"; do
    if [[ -f "$knob" ]]; then
        if ! grep -q '\[within_size\]' "$knob"; then
            printf 'within_size\n' | run_priv tee "$knob" >/dev/null
        fi
    fi
done

TMPFILES_CONF="${HFT_ROOT}/etc/tmpfiles.d/hft-shm-thp.conf"
txn_record_file "$TMPFILES_CONF"
atomic_write_priv "$TMPFILES_CONF" 0644 0:0 <<'EOF'
# Managed by 05_memory_net_and_limits.sh: enable 2MB shmem THP (within_size)
w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - within_size
w /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled - - - - within_size
EOF

# 8. Three hft-scoped limits files (NEVER global *)
LIMITS_PAM="${HFT_ROOT}/etc/security/limits.d/99-hft.conf"
LIMITS_USER_UNIT="${HFT_ROOT}/etc/systemd/system/user@${HFT_UID}.service.d/99-hft-limits.conf"
LIMITS_USER_SVC="${HFT_HOME}/.config/systemd/user/service.d/99-hft-limits.conf"

txn_record_file "$LIMITS_PAM"
txn_record_file "$LIMITS_USER_UNIT"
txn_record_file "$LIMITS_USER_SVC"

atomic_write_priv "$LIMITS_PAM" 0644 0:0 <<'EOF'
# Managed by 05_memory_net_and_limits.sh (scoped exclusively to user hft)
hft soft memlock unlimited
hft hard memlock unlimited
hft soft nofile 1048576
hft hard nofile 1048576
hft soft rtprio 99
hft hard rtprio 99
EOF

atomic_write_priv "$LIMITS_USER_UNIT" 0644 0:0 <<'EOF'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitRTPRIO=99
EOF

run_priv mkdir -p "$(dirname "$LIMITS_USER_SVC")"
run_priv "$HFT_CHOWN_CMD" -R "${HFT_UID}:${HFT_GID}" "${HFT_HOME}/.config"
atomic_write_priv "$LIMITS_USER_SVC" 0644 "${HFT_UID}:${HFT_GID}" <<'EOF'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitRTPRIO=99
EOF

run_priv "$HFT_SYSTEMCTL_CMD" daemon-reload

# Self-verify
bash "${SCRIPT_DIR}/verify_05_memory_net_and_limits.sh" --staged
log_success "Layer 1 Step 05 complete."
