#!/usr/bin/env bash
# Layer 2 Step 02: Configure generic Git defaults, ~/.ssh/config.d Include,
# and GitHub official SSH host keys (ED25519 + RSA). Strictly zero sudo.
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

banner "Layer 2 Step 02: Generic Git & SSH Base Configuration"

# Prerequisites: Layer 1 --live + Layer 2 Step 01
bash "${SCRIPT_DIR}/../00_sudo_script/verify_all.sh" --live
run_verify_chain "${SCRIPT_DIR}/verify_01_user_workspace.sh"

# 1. Generic Git defaults (no private identity or repo URLs)
git config --global init.defaultBranch main
git config --global pull.ff only
git config --global fetch.prune true

# 2. ~/.ssh/config.d (0700) and ~/.ssh/config (0600) with Include ~/.ssh/config.d/*.conf
SSH_DIR="${HOME}/.ssh"
SSH_CONF_D="${SSH_DIR}/config.d"
SSH_CONF="${SSH_DIR}/config"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"

mkdir -p "$SSH_CONF_D"
"$HFT_CHMOD_CMD" 0700 "$SSH_DIR" "$SSH_CONF_D"

INCLUDE_LINE="Include ~/.ssh/config.d/*.conf"
if [[ ! -f "$SSH_CONF" ]]; then
    printf '%s\n' "$INCLUDE_LINE" > "$SSH_CONF"
elif ! grep -Fqx "$INCLUDE_LINE" "$SSH_CONF"; then
    # Prepend Include at top so Include applies globally (OpenSSH evaluates Include top-down)
    tmp_cfg="$(mktemp /tmp/hft_ssh_cfg.XXXXXX)"
    {
        printf '%s\n' "$INCLUDE_LINE"
        cat "$SSH_CONF"
    } > "$tmp_cfg"
    mv -f "$tmp_cfg" "$SSH_CONF"
fi
"$HFT_CHMOD_CMD" 0600 "$SSH_CONF"

# 3. Idempotently add official GitHub public host keys (ED25519 + RSA)
GH_ED25519="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
GH_RSA="github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="

touch "$KNOWN_HOSTS"
"$HFT_CHMOD_CMD" 0600 "$KNOWN_HOSTS"

for key_line in "$GH_ED25519" "$GH_RSA"; do
    if ! grep -Fqx "$key_line" "$KNOWN_HOSTS"; then
        printf '%s\n' "$key_line" >> "$KNOWN_HOSTS"
    fi
done

# Self-verify
bash "${SCRIPT_DIR}/verify_02_git_ssh_base.sh"
log_success "Layer 2 Step 02 complete."
