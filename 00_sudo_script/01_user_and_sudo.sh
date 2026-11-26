#!/usr/bin/env bash
# Layer 1 Step 01: Create/configure 'hft' account, NOPASSWD sudo, SSH keys,
# systemd linger, /etc/hft, and boot-time attestation unit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

usage() {
    cat <<'EOF'
Usage: 01_user_and_sudo.sh [options]

Options:
  --ssh-key-source <user|file>  Explicit SSH public key source (username or file path)
  -h, --help                    Show this help message
EOF
}

SSH_KEY_SOURCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-key-source)
            [[ $# -ge 2 ]] || die "--ssh-key-source requires a username or file path"
            SSH_KEY_SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

banner "Layer 1 Step 01: User 'hft', Sudo, SSH Keys, and Attestation"

# Support starting as root when sudo package is not yet installed
if ! is_effective_root; then
    require_priv_ready
fi

resolve_user_home() {
    local uname="$1"
    local entry=""
    entry="$("$HFT_GETENT_CMD" passwd "$uname" 2>/dev/null || true)"
    if [[ -n "$entry" ]]; then
        local h
        h="$(printf '%s\n' "$entry" | awk -F: '{print $6}')"
        if [[ -n "$HFT_ROOT" && "$h" != "${HFT_ROOT}"* ]]; then
            printf '%s%s\n' "$HFT_ROOT" "$h"
        else
            printf '%s\n' "$h"
        fi
        return 0
    fi
    if [[ "$uname" == "root" ]]; then
        printf '%s/root\n' "$HFT_ROOT"
    else
        printf '%s/home/%s\n' "$HFT_ROOT" "$uname"
    fi
}

# Resolve SINGLE highest-priority SSH key source BEFORE mutating anything (fail-closed)
resolve_ssh_key_source_file() {
    local src="$SSH_KEY_SOURCE"
    if [[ -n "$src" ]]; then
        if [[ -f "$src" ]]; then
            printf '%s\n' "$src"
            return 0
        fi
        local uh
        uh="$(resolve_user_home "$src")"
        if [[ -f "${uh}/.ssh/authorized_keys" ]]; then
            printf '%s\n' "${uh}/.ssh/authorized_keys"
            return 0
        fi
        die "Specified --ssh-key-source '$src' not found as file or user authorized_keys."
    fi

    # Priority: SUDO_USER (non-root) > ubuntu > root (single source only, never merge)
    local cand=""
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        cand="$(resolve_user_home "$SUDO_USER")/.ssh/authorized_keys"
        if [[ -r "$cand" ]] && filter_ssh_authorized_keys "$cand" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    fi

    cand="$(resolve_user_home "ubuntu")/.ssh/authorized_keys"
    if [[ -r "$cand" ]] && filter_ssh_authorized_keys "$cand" >/dev/null 2>&1; then
        printf '%s\n' "$cand"
        return 0
    fi

    cand="$(resolve_user_home "root")/.ssh/authorized_keys"
    if [[ -r "$cand" ]] && filter_ssh_authorized_keys "$cand" >/dev/null 2>&1; then
        printf '%s\n' "$cand"
        return 0
    fi

    die "No usable SSH public key found (checked SUDO_USER, ubuntu, root). Pass --ssh-key-source <user|file>."
}

SOURCE_KEY_FILE="$(resolve_ssh_key_source_file)"
log_info "Selected single SSH key source: $SOURCE_KEY_FILE"

FILTERED_KEYS="$(filter_ssh_authorized_keys "$SOURCE_KEY_FILE")" || \
    die "SSH key source '$SOURCE_KEY_FILE' contains no valid usable public keys after filtering."

TMP_KEY_CHECK="$(mktemp /tmp/hft_keycheck.XXXXXX)"
cleanup_tmp_files() {
    [[ -n "${TMP_KEY_CHECK:-}" && -e "$TMP_KEY_CHECK" ]] && safe_rm_tmp "$TMP_KEY_CHECK" || true
    [[ -n "${TMP_SUDOERS:-}" && -e "$TMP_SUDOERS" ]] && safe_rm_tmp "$TMP_SUDOERS" || true
}
trap cleanup_tmp_files EXIT

printf '%s\n' "$FILTERED_KEYS" > "$TMP_KEY_CHECK"
SOURCE_FP="$(compute_ssh_keyfile_fp "$TMP_KEY_CHECK")" || \
    die "Failed to compute SSH public key fingerprint from $SOURCE_KEY_FILE"
log_info "Verified SSH key fingerprint(s): $SOURCE_FP"

# If 'hft' already exists with authorized_keys, verify fingerprint matches BEFORE making changes
HFT_EXISTS=0
if "$HFT_ID_CMD" -u hft >/dev/null 2>&1; then
    HFT_EXISTS=1
    HFT_HOME_PRE="$(resolve_user_home "hft")"
    if [[ -f "${HFT_HOME_PRE}/.ssh/authorized_keys" ]]; then
        EXISTING_FP="$(compute_ssh_keyfile_fp "${HFT_HOME_PRE}/.ssh/authorized_keys" || true)"
        if [[ -z "$EXISTING_FP" ]]; then
            die "Existing ${HFT_HOME_PRE}/.ssh/authorized_keys has no valid keys; reconcile manually."
        fi
        if [[ "$EXISTING_FP" != "$SOURCE_FP" ]]; then
            die "Fingerprint mismatch for existing hft account: existing='${EXISTING_FP}' vs source='${SOURCE_FP}'. Refusing to overwrite silently."
        fi
        log_info "Existing hft authorized_keys fingerprint matches source."
    fi
fi

# Start transaction now that preflight passed
txn_init "01_user_and_sudo"

# Install sudo if missing (e.g. minimal root-only image)
SUDO_BIN="${HFT_SUDO_CMD:-sudo}"
if ! command -v "$SUDO_BIN" >/dev/null 2>&1; then
    if is_effective_root; then
        log_info "sudo not found; installing sudo package..."
        run_priv "$HFT_APT_CMD" update -qq
        run_priv "$HFT_APT_CMD" install -y sudo
        txn_record_kv pkg_installed sudo "1"
    else
        die "sudo not found and current user is not root."
    fi
fi

# Create or reconcile 'hft' account
if (( HFT_EXISTS == 0 )); then
    log_info "Creating user 'hft' with /bin/bash and sudo group..."
    run_priv "$HFT_USERADD_CMD" -m -s /bin/bash -G sudo hft
else
    log_info "User 'hft' already exists; ensuring shell=/bin/bash and sudo group..."
    run_priv "$HFT_USERMOD_CMD" -s /bin/bash -aG sudo hft
fi

HFT_UID="$("$HFT_ID_CMD" -u hft)"
HFT_GID="$("$HFT_ID_CMD" -g hft)"
HFT_HOME="$(resolve_user_home "hft")"

# Install authorized_keys for hft
HFT_SSH_DIR="${HFT_HOME}/.ssh"
HFT_AUTH_KEYS="${HFT_SSH_DIR}/authorized_keys"
txn_record_file "$HFT_AUTH_KEYS"
run_priv mkdir -p "$HFT_SSH_DIR"
run_priv "$HFT_CHMOD_CMD" 0700 "$HFT_SSH_DIR"
run_priv "$HFT_CHOWN_CMD" "${HFT_UID}:${HFT_GID}" "$HFT_SSH_DIR"
printf '%s\n' "$FILTERED_KEYS" | atomic_write_priv "$HFT_AUTH_KEYS" 0600 "${HFT_UID}:${HFT_GID}"

# Validate and install /etc/sudoers.d/90-hft-nopasswd
SUDOERS_DST="${HFT_ROOT}/etc/sudoers.d/90-hft-nopasswd"
TMP_SUDOERS="$(mktemp /tmp/hft_sudoers.XXXXXX)"
printf 'hft ALL=(ALL) NOPASSWD:ALL\n' > "$TMP_SUDOERS"
chmod 0440 "$TMP_SUDOERS"

if ! run_priv "$HFT_VISUDO_CMD" -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    die "visudo validation failed for candidate sudoers file."
fi

txn_record_file "$SUDOERS_DST"
cat "$TMP_SUDOERS" | atomic_write_priv "$SUDOERS_DST" 0440 0:0

if ! run_priv "$HFT_VISUDO_CMD" -c >/dev/null 2>&1; then
    log_error "Global visudo -c failed; rolling back."
    txn_rollback
    exit 1
fi

SUDO_L_OUT="$(run_priv "$SUDO_BIN" -l -U hft 2>&1 || true)"
if ! printf '%s\n' "$SUDO_L_OUT" | grep -Eq 'NOPASSWD:[[:space:]]*ALL'; then
    log_error "sudo -l -U hft did not confirm NOPASSWD: ALL; rolling back."
    txn_rollback
    exit 1
fi

# Enable systemd user linger for hft
log_info "Enabling linger for user 'hft'..."
run_priv "$HFT_LOGINCTL_CMD" enable-linger hft

# Create /etc/hft
ETC_HFT="${HFT_ROOT}/etc/hft"
run_priv mkdir -p "$ETC_HFT"
run_priv "$HFT_CHMOD_CMD" 0755 "$ETC_HFT"
run_priv "$HFT_CHOWN_CMD" 0:0 "$ETC_HFT"

# Install boot-time privileged attestation script & systemd service
ATTEST_SCRIPT="${HFT_ROOT}/usr/local/sbin/hft-attest-account.sh"
ATTEST_UNIT="${HFT_ROOT}/etc/systemd/system/hft-verify-account.service"

txn_record_file "$ATTEST_SCRIPT"
txn_record_file "$ATTEST_UNIT"
txn_record_kv unit_state "hft-verify-account.service" "$(systemctl_state_pair hft-verify-account.service)"

atomic_write_priv "$ATTEST_SCRIPT" 0755 0:0 <<'EOF'
#!/usr/bin/env bash
# Boot-time privileged account/sudoers attestation for Layer 1 Step 01.
set -euo pipefail

HFT_ROOT="${HFT_ROOT:-}"
while [[ -n "$HFT_ROOT" && "$HFT_ROOT" != "/" && "${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="${HFT_ROOT%/}"
done
[[ "$HFT_ROOT" == "/" ]] && HFT_ROOT=""

HFT_RUN_DIR="${HFT_RUN_DIR:-${HFT_ROOT}/run/hft-bootstrap}"
HFT_VISUDO_CMD="${HFT_VISUDO_CMD:-visudo}"
HFT_SUDO_CMD="${HFT_SUDO_CMD:-sudo}"
HFT_ID_CMD="${HFT_ID_CMD:-id}"
HFT_GETENT_CMD="${HFT_GETENT_CMD:-getent}"
HFT_SSH_KEYGEN_CMD="${HFT_SSH_KEYGEN_CMD:-ssh-keygen}"
HFT_STAT_CMD="${HFT_STAT_CMD:-stat}"
HFT_SHA256SUM_CMD="${HFT_SHA256SUM_CMD:-sha256sum}"
HFT_CHMOD_CMD="${HFT_CHMOD_CMD:-chmod}"
HFT_CHOWN_CMD="${HFT_CHOWN_CMD:-chown}"

SUDOERS_FILE="${HFT_ROOT}/etc/sudoers.d/90-hft-nopasswd"
OUT_FILE="${HFT_RUN_DIR}/layer1_01.verified"

[[ -f "$SUDOERS_FILE" ]] || { echo "Error: missing $SUDOERS_FILE" >&2; exit 1; }
ug="$("$HFT_STAT_CMD" -c '%u:%g' "$SUDOERS_FILE")"
mode="$("$HFT_STAT_CMD" -c '%a' "$SUDOERS_FILE")"
[[ "$ug" == "0:0" ]] || { echo "Error: $SUDOERS_FILE owner is $ug (expected 0:0)" >&2; exit 1; }
[[ "$mode" == "440" || "$mode" == "0440" ]] || { echo "Error: $SUDOERS_FILE mode is $mode (expected 440)" >&2; exit 1; }

"$HFT_VISUDO_CMD" -c >/dev/null
sudo_out="$("$HFT_SUDO_CMD" -l -U hft 2>&1)"
printf '%s\n' "$sudo_out" | grep -Eq 'NOPASSWD:[[:space:]]*ALL' || { echo "Error: sudo -l -U hft missing NOPASSWD:ALL" >&2; exit 1; }

hft_uid="$("$HFT_ID_CMD" -u hft)"
entry="$("$HFT_GETENT_CMD" passwd hft 2>/dev/null || true)"
if [[ -n "$entry" ]]; then
    hft_home="$(printf '%s\n' "$entry" | awk -F: '{print $6}')"
    if [[ -n "$HFT_ROOT" && "$hft_home" != "${HFT_ROOT}"* ]]; then
        hft_home="${HFT_ROOT}${hft_home}"
    fi
else
    hft_home="${HFT_ROOT}/home/hft"
fi

auth_keys="${hft_home}/.ssh/authorized_keys"
[[ -r "$auth_keys" ]] || { echo "Error: unreadable $auth_keys" >&2; exit 1; }
if grep -q "Please login as the user" "$auth_keys"; then
    echo "Error: refusal line present in $auth_keys" >&2
    exit 1
fi
pubkey_fp="$("$HFT_SSH_KEYGEN_CMD" -lf /dev/stdin < "$auth_keys" 2>/dev/null | awk '{print $2}' | sort -u | paste -sd ',' -)"
[[ -n "$pubkey_fp" ]] || { echo "Error: empty pubkey fingerprint for $auth_keys" >&2; exit 1; }

boot_id="$(tr -d '[:space:]' < "${HFT_ROOT}/proc/sys/kernel/random/boot_id")"
[[ -n "$boot_id" ]] || { echo "Error: empty boot_id" >&2; exit 1; }

if command -v "$HFT_SHA256SUM_CMD" >/dev/null 2>&1; then
    sudoers_sha256="$("$HFT_SHA256SUM_CMD" "$SUDOERS_FILE" | awk '{print $1}')"
else
    sudoers_sha256="$(shasum -a 256 "$SUDOERS_FILE" | awk '{print $1}')"
fi

mkdir -p "$HFT_RUN_DIR"
stage="${OUT_FILE}.tmp.$$"
cat > "$stage" <<ATTEST
boot_id=${boot_id}
hft_uid=${hft_uid}
pubkey_fp=${pubkey_fp}
sudoers_sha256=${sudoers_sha256}
ATTEST
"$HFT_CHMOD_CMD" 0644 "$stage"
"$HFT_CHOWN_CMD" 0:0 "$stage"
mv -f "$stage" "$OUT_FILE"
EOF

atomic_write_priv "$ATTEST_UNIT" 0644 0:0 <<'EOF'
[Unit]
Description=HFT Layer 1 Account and Sudoers Boot Attestation
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hft-attest-account.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run_priv "$HFT_SYSTEMCTL_CMD" daemon-reload
run_priv "$HFT_SYSTEMCTL_CMD" enable hft-verify-account.service
run_priv "$ATTEST_SCRIPT"
run_priv "$HFT_SYSTEMCTL_CMD" start hft-verify-account.service

# Self-verify
bash "${SCRIPT_DIR}/verify_01_user_and_sudo.sh" --staged

log_success "Layer 1 Step 01 complete."
echo ""
log_warn "IMPORTANT: Before rebooting or closing this session, open a NEW terminal and verify:"
echo "  ssh hft@<host> 'sudo -n true'"
