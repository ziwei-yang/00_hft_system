#!/usr/bin/env bash
# Layer 1 Step 02: Set timezone Asia/Hong_Kong, install base build/HFT packages, enable cron.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_priv_ready

banner "Layer 1 Step 02: Base Packages and Timezone"

# Prerequisite pure read-only verifier chain
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"

txn_init "02_base_packages_and_tz"

# 1. Timezone -> Asia/Hong_Kong
OLD_TZ="$("$HFT_TIMEDATECTL_CMD" show -p Timezone --value 2>/dev/null || true)"
if [[ -z "$OLD_TZ" && -r "${HFT_ROOT}/etc/timezone" ]]; then
    OLD_TZ="$(tr -d '[:space:]' < "${HFT_ROOT}/etc/timezone")"
fi
if [[ -n "$OLD_TZ" && "$OLD_TZ" != "Asia/Hong_Kong" ]]; then
    txn_record_kv timezone tz "$OLD_TZ"
    log_info "Setting timezone: ${OLD_TZ} -> Asia/Hong_Kong"
    run_priv "$HFT_TIMEDATECTL_CMD" set-timezone Asia/Hong_Kong
else
    log_info "Timezone already Asia/Hong_Kong."
fi

# 2. Idempotent package installation
REQUIRED_PKGS=(
    build-essential g++ gcc make cmake pkg-config autoconf automake libtool
    git ca-certificates liburing-dev zlib1g-dev libssl-dev dpdk libdpdk-dev
    python3 python3-pip python3-venv cron ethtool iproute2 net-tools tcpdump
    curl wget jq tmux htop sysstat numactl rsync unzip openssh-client
)

declare -a MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    status="$("$HFT_DPKG_CMD" -s "$pkg" 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
    if [[ "$status" != "install ok installed" ]]; then
        MISSING_PKGS+=("$pkg")
    fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
    log_info "Installing ${#MISSING_PKGS[@]} missing package(s): ${MISSING_PKGS[*]}"
    run_priv "$HFT_APT_CMD" update -qq
    run_priv "$HFT_APT_CMD" install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do
        txn_record_kv pkg_installed "$pkg" "1"
    done
else
    log_info "All ${#REQUIRED_PKGS[@]} required packages are already installed."
fi

# 3. Enable and start cron
txn_record_kv unit_state "cron" "$(systemctl_state_pair cron)"
run_priv "$HFT_SYSTEMCTL_CMD" enable cron
run_priv "$HFT_SYSTEMCTL_CMD" start cron

# Self-verify
bash "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
log_success "Layer 1 Step 02 complete."
