#!/usr/bin/env bash
# Pure read-only Layer 2 verification suite (plus Layer 1 --live gate).
# Strictly zero sudo, non-root, NEVER writes any file.
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

TLS_TARGET="${1:-all}"
case "$TLS_TARGET" in
    wolfssl|openssl|libressl|all) ;;
    -h|--help)
        echo "Usage: 01_startup/verify_all.sh [wolfssl|openssl|libressl|all]"
        exit 0
        ;;
    *) die "Unknown TLS target: $TLS_TARGET" ;;
esac

banner "Layer 2 Verification Suite (Zero Sudo)"

bash "${SCRIPT_DIR}/../00_sudo_script/verify_all.sh" --live
bash "${SCRIPT_DIR}/verify_01_user_workspace.sh"
bash "${SCRIPT_DIR}/verify_02_git_ssh_base.sh"
bash "${SCRIPT_DIR}/verify_03_build_tls_libs.sh" "$TLS_TARGET"

log_success "Layer 2 verify_all: ALL CHECKS PASSED."
