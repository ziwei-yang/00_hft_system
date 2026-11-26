#!/usr/bin/env bash
# Layer 2 orchestrator: runs steps 01..03 in order as non-root user 'hft' (strictly zero sudo).
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
        echo "Usage: 01_startup/run_all.sh [wolfssl|openssl|libressl|all]"
        exit 0
        ;;
    *) die "Unknown TLS target: $TLS_TARGET" ;;
esac

banner "Layer 2: User-Level Bootstrap (Strictly Zero Sudo)"

bash "${SCRIPT_DIR}/01_user_workspace.sh"
bash "${SCRIPT_DIR}/02_git_ssh_base.sh"
bash "${SCRIPT_DIR}/03_build_tls_libs.sh" "$TLS_TARGET"

bash "${SCRIPT_DIR}/verify_all.sh" "$TLS_TARGET"
log_success "Layer 2 bootstrap complete."
