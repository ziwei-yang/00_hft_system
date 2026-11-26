#!/usr/bin/env bash
# Layer 1 Step 06: Disable/mask background apt noise and cap systemd-journald disk usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_priv_ready

banner "Layer 1 Step 06: Disable Background Noise and Cap Journald"

# Prerequisite pure read-only verifiers
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"
run_verify_chain "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_04_irq_nic_and_perf.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_05_memory_net_and_limits.sh"

txn_init "06_disable_bg_noise"

# 1. Stop, disable, and mask unattended-upgrades and apt daily timers
NOISE_UNITS=(
    unattended-upgrades.service
    apt-daily.timer
    apt-daily-upgrade.timer
)

for unit in "${NOISE_UNITS[@]}"; do
    st="$(systemctl_state_pair "$unit")"
    txn_record_kv unit_state "$unit" "$st"
    if [[ "${st#*:}" == "active" ]]; then
        run_priv "$HFT_SYSTEMCTL_CMD" stop "$unit"
    fi
    if [[ "${st%%:*}" != "masked" && "${st%%:*}" != "not-found" ]]; then
        run_priv "$HFT_SYSTEMCTL_CMD" disable "$unit" 2>/dev/null || true
        run_priv "$HFT_SYSTEMCTL_CMD" mask "$unit"
    fi
done

# 2. Write /etc/apt/apt.conf.d/20auto-upgrades
AUTO_UPG="${HFT_ROOT}/etc/apt/apt.conf.d/20auto-upgrades"
txn_record_file "$AUTO_UPG"
atomic_write_priv "$AUTO_UPG" 0644 0:0 <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

# 3. Write /etc/systemd/journald.conf.d/99-hft.conf and restart systemd-journald
JOURNAL_CONF="${HFT_ROOT}/etc/systemd/journald.conf.d/99-hft.conf"
txn_record_file "$JOURNAL_CONF"
atomic_write_priv "$JOURNAL_CONF" 0644 0:0 <<'EOF'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=14day
EOF

run_priv "$HFT_SYSTEMCTL_CMD" restart systemd-journald

# Self-verify
bash "${SCRIPT_DIR}/verify_06_disable_bg_noise.sh"
log_success "Layer 1 Step 06 complete."
