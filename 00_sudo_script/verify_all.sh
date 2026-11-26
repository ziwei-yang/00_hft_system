#!/usr/bin/env bash
# Pure read-only Layer 1 verification suite (steps 01..07).
# NEVER writes any file and NEVER invokes sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

MODE="staged"
REQ_EXCHANGE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --live)   MODE="live";   shift ;;
        --require-exchange-time) REQ_EXCHANGE=true; shift ;;
        -h|--help)
            echo "Usage: 00_sudo_script/verify_all.sh [--staged|--live] [--require-exchange-time]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

banner "Layer 1 Verification Suite (mode=${MODE})"

bash "${SCRIPT_DIR}/verify_01_user_and_sudo.sh" "--${MODE}"
bash "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh" "--${MODE}"
bash "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh" "--${MODE}"
bash "${SCRIPT_DIR}/verify_04_irq_nic_and_perf.sh" "--${MODE}"
bash "${SCRIPT_DIR}/verify_05_memory_net_and_limits.sh" "--${MODE}"
bash "${SCRIPT_DIR}/verify_06_disable_bg_noise.sh" "--${MODE}"
if [[ "$REQ_EXCHANGE" == true ]]; then
    bash "${SCRIPT_DIR}/verify_07_chrony_time_sync.sh" "--${MODE}" --require-exchange-time
else
    bash "${SCRIPT_DIR}/verify_07_chrony_time_sync.sh" "--${MODE}"
fi

log_success "Layer 1 verify_all (${MODE}): ALL 7 STEPS PASSED."
