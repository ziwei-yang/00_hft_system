#!/usr/bin/env bash
# Layer 1 orchestrator: runs steps 01..07 in order and verifies staged state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

SSH_KEY_SOURCE=""
EXTRA_GRUB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-key-source)
            [[ $# -ge 2 ]] || die "--ssh-key-source requires a value"
            SSH_KEY_SOURCE="$2"
            shift 2
            ;;
        --max-phys-cores)
            [[ $# -ge 2 ]] || die "--max-phys-cores requires a value"
            EXTRA_GRUB_ARGS+=("--max-phys-cores" "$2")
            shift 2
            ;;
        --enable-idle-poll|--no-managed-irq)
            EXTRA_GRUB_ARGS+=("$1")
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: 00_sudo_script/run_all.sh [options]

Options:
  --ssh-key-source <user|file>  Forwarded to 01_user_and_sudo.sh
  --max-phys-cores <N>          Forwarded to 03_grub_cpu_isolation.sh
  --enable-idle-poll            Forwarded to 03_grub_cpu_isolation.sh
  --no-managed-irq              Forwarded to 03_grub_cpu_isolation.sh
  -h, --help                    Show this help message
EOF
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

banner "Layer 1: Full System Bootstrap (Steps 01..07)"

if [[ -n "$SSH_KEY_SOURCE" ]]; then
    bash "${SCRIPT_DIR}/01_user_and_sudo.sh" --ssh-key-source "$SSH_KEY_SOURCE"
else
    bash "${SCRIPT_DIR}/01_user_and_sudo.sh"
fi

bash "${SCRIPT_DIR}/02_base_packages_and_tz.sh"

if (( ${#EXTRA_GRUB_ARGS[@]} > 0 )); then
    bash "${SCRIPT_DIR}/03_grub_cpu_isolation.sh" "${EXTRA_GRUB_ARGS[@]}"
else
    bash "${SCRIPT_DIR}/03_grub_cpu_isolation.sh"
fi

bash "${SCRIPT_DIR}/04_irq_nic_and_perf.sh"
bash "${SCRIPT_DIR}/05_memory_net_and_limits.sh"
bash "${SCRIPT_DIR}/06_disable_bg_noise.sh"
bash "${SCRIPT_DIR}/07_chrony_time_sync.sh"

bash "${SCRIPT_DIR}/verify_all.sh" --staged

echo ""
log_success "Layer 1 staged bootstrap complete."
log_warn "NEXT STEPS:"
echo "  1. Open a NEW terminal and test: ssh hft@<host> 'sudo -n true'"
echo "  2. Reboot the host: sudo reboot"
echo "  3. After reboot, log in as 'hft' and run:"
echo "       ./00_sudo_script/verify_all.sh --live"
echo "       ./01_startup/run_all.sh"
