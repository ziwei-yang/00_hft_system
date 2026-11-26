#!/usr/bin/env bash
# Layer 2 Step 01: Initialize hft user workspace directories (strictly zero sudo, non-root).
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

banner "Layer 2 Step 01: User Workspace Initialization"

# Prerequisite: Layer 1 live verification (100% pure read-only, zero sudo)
bash "${SCRIPT_DIR}/../00_sudo_script/verify_all.sh" --live

mkdir -p \
    "${HOME}/Proj" \
    "${HOME}/etc" \
    "${HOME}/log" \
    "${HOME}/.config/hft" \
    "${HOME}/.config/systemd/user" \
    "${HOME}/.ssh"

"$HFT_CHMOD_CMD" 0700 "${HOME}/.config/hft"
"$HFT_CHMOD_CMD" 0700 "${HOME}/.ssh"

# Self-verify
bash "${SCRIPT_DIR}/verify_01_user_workspace.sh"
log_success "Layer 2 Step 01 complete."
