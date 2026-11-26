#!/usr/bin/env bash
# Shared bootstrap library for 00_hft_system (Layer 1 & Layer 2).
# Must be sourced by scripts running under GNU bash >= 4.3.

if [[ -n "${_HFT_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
_HFT_COMMON_SH_LOADED=1
export PYTHONDONTWRITEBYTECODE=1

# ------------------------------------------------------------------------------
# Injectable paths and environment switches
# ------------------------------------------------------------------------------
HFT_ROOT="${HFT_ROOT:-}"
# Strip trailing slashes from non-empty HFT_ROOT (except root itself).
while [[ -n "$HFT_ROOT" && "$HFT_ROOT" != "/" && "${HFT_ROOT}" == */ ]]; do
    HFT_ROOT="${HFT_ROOT%/}"
done
if [[ "$HFT_ROOT" == "/" ]]; then
    HFT_ROOT=""
fi

HFT_STATE_DIR="${HFT_STATE_DIR:-${HFT_ROOT}/var/lib/hft-bootstrap}"
HFT_RUN_DIR="${HFT_RUN_DIR:-${HFT_ROOT}/run/hft-bootstrap}"
HFT_SKIP_OS_CHECK="${HFT_SKIP_OS_CHECK:-0}"
HFT_EC2_MODE="${HFT_EC2_MODE:-}"
HFT_SUDO_CMD="${HFT_SUDO_CMD:-}"
HFT_NO_SUDO="${HFT_NO_SUDO:-0}"
HFT_PRETEND_ROOT="${HFT_PRETEND_ROOT:-0}"

# Injectable command names for sandboxed testing
HFT_APT_CMD="${HFT_APT_CMD:-apt-get}"
HFT_DPKG_CMD="${HFT_DPKG_CMD:-dpkg}"
HFT_DPKG_DEB_CMD="${HFT_DPKG_DEB_CMD:-dpkg-deb}"
HFT_SYSTEMCTL_CMD="${HFT_SYSTEMCTL_CMD:-systemctl}"
HFT_LOGINCTL_CMD="${HFT_LOGINCTL_CMD:-loginctl}"
HFT_TIMEDATECTL_CMD="${HFT_TIMEDATECTL_CMD:-timedatectl}"
HFT_VISUDO_CMD="${HFT_VISUDO_CMD:-visudo}"
HFT_SYSCTL_CMD="${HFT_SYSCTL_CMD:-sysctl}"
HFT_ETHTOOL_CMD="${HFT_ETHTOOL_CMD:-ethtool}"
HFT_IP_CMD="${HFT_IP_CMD:-ip}"
HFT_CHRONYC_CMD="${HFT_CHRONYC_CMD:-chronyc}"
HFT_MOUNT_CMD="${HFT_MOUNT_CMD:-mount}"
HFT_FINDMNT_CMD="${HFT_FINDMNT_CMD:-findmnt}"
HFT_UPDATE_GRUB_CMD="${HFT_UPDATE_GRUB_CMD:-update-grub}"
HFT_GRUB_SCRIPT_CHECK_CMD="${HFT_GRUB_SCRIPT_CHECK_CMD:-grub-script-check}"
HFT_GRUB_EDITENV_CMD="${HFT_GRUB_EDITENV_CMD:-grub-editenv}"
HFT_TMPFILES_CMD="${HFT_TMPFILES_CMD:-systemd-tmpfiles}"
HFT_ID_CMD="${HFT_ID_CMD:-id}"
HFT_GETENT_CMD="${HFT_GETENT_CMD:-getent}"
HFT_USERADD_CMD="${HFT_USERADD_CMD:-useradd}"
HFT_USERMOD_CMD="${HFT_USERMOD_CMD:-usermod}"
HFT_SSH_KEYGEN_CMD="${HFT_SSH_KEYGEN_CMD:-ssh-keygen}"
HFT_CHOWN_CMD="${HFT_CHOWN_CMD:-chown}"
HFT_CHMOD_CMD="${HFT_CHMOD_CMD:-chmod}"
HFT_INSTALL_CMD="${HFT_INSTALL_CMD:-install}"
HFT_STAT_CMD="${HFT_STAT_CMD:-stat}"
HFT_PKG_CONFIG_CMD="${HFT_PKG_CONFIG_CMD:-pkg-config}"
HFT_CC_CMD="${HFT_CC_CMD:-gcc}"
HFT_CXX_CMD="${HFT_CXX_CMD:-g++}"
HFT_CURL_CMD="${HFT_CURL_CMD:-curl}"
HFT_FLOCK_CMD="${HFT_FLOCK_CMD:-flock}"
HFT_SHA256SUM_CMD="${HFT_SHA256SUM_CMD:-sha256sum}"

# ------------------------------------------------------------------------------
# Colors and logging
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
log_ok()      { log_success "$@"; }
log_warn()    { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
banner()      { printf '\n%b=== %s ===%b\n' "$BLUE" "$*" "$NC"; }
die()         { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Runtime guards and platform probes
# ------------------------------------------------------------------------------
require_bash43() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        echo "Error: bash >= 4.3 is required (found ${BASH_VERSION})" >&2
        exit 1
    fi
}

require_ubuntu() {
    if [[ "${HFT_SKIP_OS_CHECK:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
        die "This script only runs on Linux (found $(uname -s))."
    fi
    local os_rel="${HFT_ROOT}/etc/os-release"
    if [[ ! -r "$os_rel" ]]; then
        die "Cannot read $os_rel to verify Ubuntu OS."
    fi
    local id_val
    id_val="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print tolower($2); exit}' "$os_rel")"
    if [[ "$id_val" != "ubuntu" ]]; then
        die "Unsupported OS (ID=${id_val:-unknown}); Ubuntu 24.04 is required."
    fi
}

is_ec2() {
    if [[ "$HFT_EC2_MODE" == "1" || "$HFT_EC2_MODE" == "true" ]]; then
        return 0
    elif [[ "$HFT_EC2_MODE" == "0" || "$HFT_EC2_MODE" == "false" ]]; then
        return 1
    elif [[ -n "$HFT_EC2_MODE" ]]; then
        die "HFT_EC2_MODE must be 0, 1, true, false, or empty (got '$HFT_EC2_MODE')."
    fi

    local asset="${HFT_ROOT}/sys/devices/virtual/dmi/id/board_asset_tag"
    local puuid="${HFT_ROOT}/sys/devices/virtual/dmi/id/product_uuid"
    local huuid="${HFT_ROOT}/sys/hypervisor/uuid"

    if [[ -r "$asset" ]] && grep -Eq '^i-' "$asset" 2>/dev/null; then
        return 0
    fi
    if [[ -r "$puuid" ]] && grep -Eq '^[Ee][Cc]2' "$puuid" 2>/dev/null; then
        return 0
    fi
    if [[ -r "$huuid" ]] && grep -Eq '^[Ee][Cc]2' "$huuid" 2>/dev/null; then
        return 0
    fi
    return 1
}

cpu_vendor_id() {
    local cpuinfo="${HFT_ROOT}/proc/cpuinfo"
    if [[ ! -r "$cpuinfo" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local v
    v="$(awk -F: '/^[[:space:]]*vendor_id[[:space:]]*:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$cpuinfo")"
    printf '%s\n' "${v:-unknown}"
}

current_boot_id() {
    local f="${HFT_ROOT}/proc/sys/kernel/random/boot_id"
    if [[ ! -r "$f" ]]; then
        log_error "Cannot read boot_id from $f"
        return 1
    fi
    local bid
    bid="$(tr -d '[:space:]' < "$f")"
    if [[ -z "$bid" ]]; then
        log_error "Empty boot_id in $f"
        return 1
    fi
    printf '%s\n' "$bid"
}

is_effective_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 || "${HFT_PRETEND_ROOT:-0}" == "1" ]]
}

run_priv() {
    if [[ "${HFT_NO_SUDO:-0}" == "1" ]]; then
        die "Privileged execution forbidden when HFT_NO_SUDO=1 (attempted: $*)"
    fi
    if [[ $# -eq 0 ]]; then
        die "run_priv called with no arguments"
    fi
    if is_effective_root; then
        "$@"
    else
        "${HFT_SUDO_CMD:-sudo}" "$@"
    fi
}

require_priv_ready() {
    if [[ "${HFT_NO_SUDO:-0}" == "1" ]]; then
        die "Privileged execution forbidden when HFT_NO_SUDO=1"
    fi
    if is_effective_root; then
        return 0
    fi
    local sc="${HFT_SUDO_CMD:-sudo}"
    if ! command -v "$sc" >/dev/null 2>&1; then
        die "Command '$sc' not found and not running as root."
    fi
    if ! "$sc" -n true 2>/dev/null; then
        die "sudo requires a password. Run 'sudo -v' or configure NOPASSWD first."
    fi
}

require_not_root() {
    if [[ "${HFT_PRETEND_ROOT:-0}" == "1" ]]; then
        die "This Layer 2 script must NOT run as root (HFT_PRETEND_ROOT=1)."
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        die "This Layer 2 script must NOT run as root. Switch to user 'hft'."
    fi
}

# Run a sequence of pure read-only verifier scripts.
# Usage: run_verify_chain [--arg <arg>] -- <script1> [script2 ...]
#    or: run_verify_chain <script1> [script2 ...]
run_verify_chain() {
    local -a extra_args=()
    local -a scripts=()
    local parsing_opts=1
    while [[ $# -gt 0 ]]; do
        if (( parsing_opts )); then
            case "$1" in
                --arg)
                    [[ $# -ge 2 ]] || die "run_verify_chain: --arg requires value"
                    extra_args+=("$2")
                    shift 2
                    ;;
                --)
                    parsing_opts=0
                    shift
                    ;;
                *)
                    parsing_opts=0
                    scripts+=("$1")
                    shift
                    ;;
            esac
        else
            scripts+=("$1")
            shift
        fi
    done

    local s
    for s in "${scripts[@]}"; do
        if [[ ! -f "$s" ]]; then
            die "Prerequisite verifier not found: $s"
        fi
        log_info "Running prerequisite verifier: $(basename "$s") ${extra_args[*]:-}"
        if (( ${#extra_args[@]} > 0 )); then
            if ! bash "$s" "${extra_args[@]}"; then
                die "Prerequisite verifier failed: $s ${extra_args[*]}"
            fi
        else
            if ! bash "$s"; then
                die "Prerequisite verifier failed: $s"
            fi
        fi
    done
}

# ------------------------------------------------------------------------------
# Safe path removal (strict literal absolute prefix enforcement)
# ------------------------------------------------------------------------------
safe_rm_file_priv() {
    local target="$1"
    if [[ -z "$target" || "$target" == "/" || "$target" == *"/.."* || "$target" == *"../"* ]]; then
        log_error "Refusing unsafe removal path: '$target'"
        return 1
    fi
    case "$target" in
        /tmp/*)
            run_priv rm -f /tmp/"${target#/tmp/}"
            ;;
        /etc/*)
            run_priv rm -f /etc/"${target#/etc/}"
            ;;
        /var/lib/hft-bootstrap/*)
            run_priv rm -f /var/lib/hft-bootstrap/"${target#/var/lib/hft-bootstrap/}"
            ;;
        /run/hft-bootstrap/*)
            run_priv rm -f /run/hft-bootstrap/"${target#/run/hft-bootstrap/}"
            ;;
        /usr/local/sbin/*)
            run_priv rm -f /usr/local/sbin/"${target#/usr/local/sbin/}"
            ;;
        /home/*)
            run_priv rm -f /home/"${target#/home/}"
            ;;
        *)
            log_error "Refusing removal outside whitelisted prefixes: '$target'"
            return 1
            ;;
    esac
}

safe_rm_tmp() {
    local target="$1"
    if [[ -z "$target" || "$target" != /tmp/* || "$target" == "/tmp" || "$target" == "/tmp/" || "$target" == *"/.."* || "$target" == *"../"* ]]; then
        log_error "Refusing non-/tmp removal: '$target'"
        return 1
    fi
    rm -rf /tmp/"${target#/tmp/}"
}

# ------------------------------------------------------------------------------
# File inspection helpers (stat wrappers supporting GNU Linux & mocks)
# ------------------------------------------------------------------------------
stat_ug() {
    local path="$1"
    "$HFT_STAT_CMD" -c '%u:%g' "$path" 2>/dev/null
}

stat_mode() {
    local path="$1"
    "$HFT_STAT_CMD" -c '%a' "$path" 2>/dev/null
}

sha256_file() {
    local path="$1"
    if command -v "$HFT_SHA256SUM_CMD" >/dev/null 2>&1; then
        "$HFT_SHA256SUM_CMD" "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die "Neither sha256sum nor shasum found."
    fi
}

# Atomic privileged write: reads content from stdin and installs to dest_path.
# Usage: atomic_write_priv <dest_path> <mode> [owner_group]
atomic_write_priv() {
    local dest="$1"
    local mode="$2"
    local owner="${3:-0:0}"
    local parent
    parent="$(dirname "$dest")"

    local tmp_local
    tmp_local="$(mktemp /tmp/hft_atomic.XXXXXX)"
    cat > "$tmp_local"

    run_priv mkdir -p "$parent"
    local stage="${dest}.hfttmp.$$"
    if ! run_priv cp "$tmp_local" "$stage"; then
        safe_rm_tmp "$tmp_local"
        return 1
    fi
    safe_rm_tmp "$tmp_local"

    run_priv "$HFT_CHMOD_CMD" "$mode" "$stage"
    if [[ -n "$owner" ]]; then
        run_priv "$HFT_CHOWN_CMD" "$owner" "$stage"
    fi
    run_priv mv -f "$stage" "$dest"
}

# ------------------------------------------------------------------------------
# Transaction logging and reverse-order rollback
# ------------------------------------------------------------------------------
HFT_CURRENT_TXN_DIR=""
HFT_CURRENT_TXN_LOG=""
HFT_TXN_FILE_SEQ=0

txn_init() {
    local step_name="$1"
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "0")"
    local base_dir="${HFT_STATE_DIR}/txn_log"
    HFT_CURRENT_TXN_DIR="${base_dir}/${step_name}-${ts}-$$"
    HFT_CURRENT_TXN_LOG="${HFT_CURRENT_TXN_DIR}/ops.log"
    HFT_TXN_FILE_SEQ=0

    run_priv mkdir -p "${HFT_CURRENT_TXN_DIR}/files"
    atomic_write_priv "$HFT_CURRENT_TXN_LOG" 0600 0:0 <<EOF
# txn_step=${step_name}
# txn_started=${ts}
EOF
}

txn_append_line() {
    local line="$1"
    [[ -n "$HFT_CURRENT_TXN_LOG" ]] || die "txn_init must be called before recording transaction entries."
    local tmp_f
    tmp_f="$(mktemp /tmp/hft_txn_append.XXXXXX)"
    if [[ -f "$HFT_CURRENT_TXN_LOG" ]]; then
        run_priv cat "$HFT_CURRENT_TXN_LOG" > "$tmp_f"
    fi
    printf '%s\n' "$line" >> "$tmp_f"
    run_priv cp "$tmp_f" "$HFT_CURRENT_TXN_LOG"
    run_priv "$HFT_CHMOD_CMD" 0600 "$HFT_CURRENT_TXN_LOG"
    safe_rm_tmp "$tmp_f"
}

txn_record_file() {
    local path="$1"
    [[ -n "$HFT_CURRENT_TXN_DIR" ]] || die "txn_init must be called before txn_record_file."
    HFT_TXN_FILE_SEQ=$((HFT_TXN_FILE_SEQ + 1))
    if [[ -e "$path" || -L "$path" ]]; then
        local bak_name="${HFT_TXN_FILE_SEQ}.bak"
        local bak_path="${HFT_CURRENT_TXN_DIR}/files/${bak_name}"
        local mode ug
        mode="$(stat_mode "$path" || echo "0644")"
        ug="$(stat_ug "$path" || echo "0:0")"
        run_priv cp -a "$path" "$bak_path"
        txn_append_line "FILE_RESTORE|${path}|${bak_name}|${mode}|${ug}"
    else
        txn_append_line "FILE_REMOVE|${path}"
    fi
}

# Record key/value state for rollback:
# kinds: timezone, unit_state, sysctl, coalesce, irq, governor, pkg_installed, pkg_removed, note
txn_record_kv() {
    local kind="$1"
    local key="$2"
    local value="$3"
    txn_append_line "KV|${kind}|${key}|${value}"
}

txn_rollback() {
    local txn_dir="${1:-$HFT_CURRENT_TXN_DIR}"
    local log_file="${txn_dir}/ops.log"
    if [[ -z "$txn_dir" || ! -f "$log_file" ]]; then
        log_error "txn_rollback: transaction log not found: $log_file"
        return 1
    fi

    log_warn "Rolling back transaction: $txn_dir"
    local -a lines=()
    mapfile -t lines < <(run_priv cat "$log_file")

    local idx line
    local rc=0
    for (( idx = ${#lines[@]} - 1; idx >= 0; idx-- )); do
        line="${lines[$idx]}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        local op a b c d
        IFS='|' read -r op a b c d <<< "$line"
        case "$op" in
            FILE_RESTORE)
                local target="$a"
                local bak_file="${txn_dir}/files/${b}"
                local mode="$c"
                local ug="$d"
                if [[ -e "$bak_file" || -L "$bak_file" ]]; then
                    run_priv mkdir -p "$(dirname "$target")"
                    run_priv cp -a "$bak_file" "$target" || rc=1
                    [[ -n "$mode" ]] && run_priv "$HFT_CHMOD_CMD" "$mode" "$target" 2>/dev/null || true
                    [[ -n "$ug" ]] && run_priv "$HFT_CHOWN_CMD" "$ug" "$target" 2>/dev/null || true
                fi
                ;;
            FILE_REMOVE)
                if [[ -e "$a" || -L "$a" ]]; then
                    safe_rm_file_priv "$a" || rc=1
                fi
                ;;
            KV)
                local kind="$a"
                local key="$b"
                local val="$c"
                case "$kind" in
                    timezone)
                        if [[ -n "$val" ]]; then
                            run_priv "$HFT_TIMEDATECTL_CMD" set-timezone "$val" 2>/dev/null || rc=1
                        fi
                        ;;
                    unit_state)
                        # val format: "<enabled_state>:<active_state>"
                        local u_en="${val%%:*}"
                        local u_act="${val#*:}"
                        case "$u_en" in
                            masked)
                                run_priv "$HFT_SYSTEMCTL_CMD" mask "$key" 2>/dev/null || true
                                ;;
                            enabled)
                                run_priv "$HFT_SYSTEMCTL_CMD" unmask "$key" 2>/dev/null || true
                                run_priv "$HFT_SYSTEMCTL_CMD" enable "$key" 2>/dev/null || true
                                ;;
                            disabled|static|indirect)
                                run_priv "$HFT_SYSTEMCTL_CMD" unmask "$key" 2>/dev/null || true
                                run_priv "$HFT_SYSTEMCTL_CMD" disable "$key" 2>/dev/null || true
                                ;;
                        esac
                        if [[ "$u_act" == "active" ]]; then
                            run_priv "$HFT_SYSTEMCTL_CMD" start "$key" 2>/dev/null || true
                        elif [[ "$u_act" == "inactive" || "$u_act" == "failed" ]]; then
                            run_priv "$HFT_SYSTEMCTL_CMD" stop "$key" 2>/dev/null || true
                        fi
                        ;;
                    sysctl)
                        run_priv "$HFT_SYSCTL_CMD" -w "${key}=${val}" >/dev/null 2>&1 || true
                        ;;
                    coalesce)
                        # key=<iface>, val="<adaptive_rx>:<rx_usecs>"
                        local c_ad="${val%%:*}"
                        local c_rx="${val#*:}"
                        run_priv "$HFT_ETHTOOL_CMD" -C "$key" adaptive-rx "$c_ad" rx-usecs "$c_rx" >/dev/null 2>&1 || true
                        ;;
                    irq)
                        # key=<irq_smp_affinity_list_path>, val=<old_list>
                        if [[ -w "$key" || -f "$key" ]]; then
                            printf '%s\n' "$val" | run_priv tee "$key" >/dev/null 2>&1 || true
                        fi
                        ;;
                    governor)
                        # key=<scaling_governor_path>, val=<old_governor>
                        if [[ -f "$key" ]]; then
                            printf '%s\n' "$val" | run_priv tee "$key" >/dev/null 2>&1 || true
                        fi
                        ;;
                    pkg_installed)
                        # key=<pkg_name>
                        run_priv "$HFT_APT_CMD" remove -y "$key" >/dev/null 2>&1 || rc=1
                        ;;
                    pkg_removed)
                        # key=<pkg_name>, val=<deb_path_or_empty>
                        if [[ -n "$val" && -f "$val" ]]; then
                            run_priv "$HFT_DPKG_CMD" -i "$val" >/dev/null 2>&1 || rc=1
                        else
                            run_priv "$HFT_APT_CMD" install -y "$key" >/dev/null 2>&1 || rc=1
                        fi
                        ;;
                    note)
                        :
                        ;;
                esac
                ;;
        esac
    done

    return "$rc"
}

# ------------------------------------------------------------------------------
# CPU list parsing, compression, and equality helpers
# ------------------------------------------------------------------------------
parse_cpu_list() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/}"
    if [[ ! "$raw" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
        log_error "Invalid CPU list format: '$raw'"
        return 1
    fi
    local -a parts=()
    IFS=',' read -ra parts <<< "$raw"
    local part a b i
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            a="${part%%-*}"
            b="${part#*-}"
            if (( 10#$a > 10#$b )); then
                log_error "Inverted CPU range '$part' in '$raw'"
                return 1
            fi
            for (( i = 10#$a; i <= 10#$b; i++ )); do
                printf '%d\n' "$i"
            done
        else
            printf '%d\n' "$((10#$part))"
        fi
    done
}

compress_cpu_list() {
    local -a nums=("$@")
    local n="${#nums[@]}"
    if (( n == 0 )); then
        log_error "Empty CPU list to compress"
        return 1
    fi
    local out=""
    local start="${nums[0]}"
    local prev="${nums[0]}"
    local i cur
    for (( i = 1; i < n; i++ )); do
        cur="${nums[$i]}"
        if (( cur == prev + 1 )); then
            prev="$cur"
        else
            if [[ -n "$out" ]]; then out+=","; fi
            if (( start == prev )); then out+="$start"; else out+="${start}-${prev}"; fi
            start="$cur"
            prev="$cur"
        fi
    done
    if [[ -n "$out" ]]; then out+=","; fi
    if (( start == prev )); then out+="$start"; else out+="${start}-${prev}"; fi
    printf '%s\n' "$out"
}

normalize_cpu_list() {
    local raw="$1"
    local -a expanded=()
    mapfile -t expanded < <(parse_cpu_list "$raw" | sort -nu)
    compress_cpu_list "${expanded[@]}"
}

systemctl_state_pair() {
    local unit="$1"
    local en act
    en="$("$HFT_SYSTEMCTL_CMD" is-enabled "$unit" 2>/dev/null || true)"
    [[ -z "$en" ]] && en="not-found"
    act="$("$HFT_SYSTEMCTL_CMD" is-active "$unit" 2>/dev/null || true)"
    [[ -z "$act" ]] && act="inactive"
    printf '%s:%s\n' "$en" "$act"
}

# Pure read-only SSH authorized_keys filter + fingerprint calculator.
# Emits filtered valid key lines on stdout. Returns 1 if none remain.
filter_ssh_authorized_keys() {
    local key_file="$1"
    [[ -r "$key_file" ]] || return 1
    local line
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Filter cloud-image login refusal lines
        if [[ "$line" == *"Please login as the user"* ]]; then
            continue
        fi
        # Must contain a recognized public key algorithm token
        if [[ "$line" =~ (^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
            printf '%s\n' "$line"
            count=$((count + 1))
        fi
    done < "$key_file"
    (( count > 0 ))
}

# Pure read-only canonical fingerprint digest (comma-joined sorted SHA256 fingerprints)
compute_ssh_keyfile_fp() {
    local key_file="$1"
    [[ -r "$key_file" ]] || return 1
    local filtered
    filtered="$(filter_ssh_authorized_keys "$key_file")" || return 1
    local norm_keys="" line ktype kblob
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ (^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/=]+) ]]; then
            ktype="${BASH_REMATCH[2]}"
            kblob="${BASH_REMATCH[3]}"
            norm_keys+="${ktype} ${kblob}"$'\n'
        fi
    done <<< "$filtered"
    [[ -n "$norm_keys" ]] || return 1
    local fps
    fps="$(printf '%s' "$norm_keys" | "$HFT_SSH_KEYGEN_CMD" -lf - 2>/dev/null | awk '{print $2}' | sort -u | paste -sd ',' -)"
    [[ -n "$fps" ]] || return 1
    printf '%s\n' "$fps"
}

# ------------------------------------------------------------------------------
# GRUB next-boot unique non-recovery entry resolver (pure read-only)
# Prints the resolved linux kernel command line (arguments after image path).
# Returns non-zero (fail-closed) on submenu (>), dynamic default, recovery
# entry, missing entry, or ambiguous linux lines.
# ------------------------------------------------------------------------------
grub_resolve_next_boot_linux_line() {
    local grub_cfg="$1"
    local grub_env="$2"

    [[ -r "$grub_cfg" ]] || { log_error "Cannot read GRUB config: $grub_cfg"; return 1; }

    local next_entry=""
    local saved_entry=""
    if [[ -r "$grub_env" ]]; then
        local env_lines=""
        if command -v "$HFT_GRUB_EDITENV_CMD" >/dev/null 2>&1; then
            env_lines="$("$HFT_GRUB_EDITENV_CMD" "$grub_env" list 2>/dev/null || true)"
        else
            env_lines="$(grep -E '^[A-Za-z0-9_]+=' "$grub_env" 2>/dev/null || true)"
        fi
        next_entry="$(printf '%s\n' "$env_lines" | awk -F= '$1=="next_entry"{sub(/^next_entry=/,""); print; exit}')"
        saved_entry="$(printf '%s\n' "$env_lines" | awk -F= '$1=="saved_entry"{sub(/^saved_entry=/,""); print; exit}')"
    fi

    # Resolve effective default selector via awk (handles top-level set default= and menuentry parsing)
    awk -v next_entry="$next_entry" -v saved_entry="$saved_entry" '
        BEGIN {
            depth = 0
            default_val = "0"
            default_dynamic = 0
            in_next_if = 0
            in_else = 0
            item_idx = 0
            in_entry = 0
            cur_entry_idx = -1
        }
        {
            raw = $0
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || line ~ /^#/) next

            # Track top-level set default=
            if (depth == 0 && !in_entry) {
                if (line ~ /^if[[:space:]].*next_entry/) { in_next_if = 1; in_else = 0 }
                else if (in_next_if && line ~ /^else/) { in_else = 1 }
                else if (in_next_if && line ~ /^fi([[:space:]]|$)/) { in_next_if = 0; in_else = 0 }

                if (line ~ /^set[[:space:]]+default=/) {
                    val = line
                    sub(/^set[[:space:]]+default=/, "", val)
                    sub(/[[:space:]]*;.*$/, "", val)
                    gsub(/^["'\'']|["'\'']$/, "", val)
                    # Ignore set default="${next_entry}" inside the next_entry guard block
                    if (in_next_if && !in_else && val ~ /next_entry/) {
                        # handled via next_entry variable directly
                    } else if (val == "${saved_entry}" || val == "$saved_entry" || val == "saved") {
                        default_val = (saved_entry != "" ? saved_entry : "0")
                    } else if (val ~ /\$/) {
                        default_dynamic = 1
                        default_val = val
                    } else {
                        default_val = val
                    }
                }
            }

            # Top-level submenu header
            if (depth == 0 && line ~ /^submenu[[:space:]]+/) {
                cur_idx = item_idx++
                item_kind[cur_idx] = "submenu"
                item_title[cur_idx] = extract_first_quoted(line)
                item_id[cur_idx] = extract_id(line)
                depth += count_char(line, "{") - count_char(line, "}")
                next
            }

            # Top-level menuentry header
            if (depth == 0 && line ~ /^menuentry[[:space:]]+/) {
                cur_idx = item_idx++
                item_kind[cur_idx] = "menuentry"
                item_title[cur_idx] = extract_first_quoted(line)
                item_id[cur_idx] = extract_id(line)
                item_linux_cnt[cur_idx] = 0
                item_linux[cur_idx] = ""
                in_entry = 1
                cur_entry_idx = cur_idx
                depth += count_char(line, "{") - count_char(line, "}")
                if (depth <= 0) { depth = 0; in_entry = 0; cur_entry_idx = -1 }
                next
            }

            if (in_entry && cur_entry_idx >= 0) {
                if (line ~ /^(linux|linuxefi|linux16)[[:space:]]+/) {
                    item_linux_cnt[cur_entry_idx]++
                    # Strip command and kernel path, keeping kernel cmdline params
                    cmdline = line
                    sub(/^(linux|linuxefi|linux16)[[:space:]]+[^[:space:]]+[[:space:]]*/, "", cmdline)
                    item_linux[cur_entry_idx] = cmdline
                }
            }

            depth += count_char(line, "{") - count_char(line, "}")
            if (depth <= 0) {
                depth = 0
                in_entry = 0
                cur_entry_idx = -1
            }
        }
        function count_char(s, ch,   i, c) {
            c = 0
            for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) c++
            return c
        }
        function extract_first_quoted(s,   q, rest, pos) {
            pos = index(s, "\x27")
            q = "\x27"
            pos2 = index(s, "\"")
            if (pos == 0 || (pos2 > 0 && pos2 < pos)) { pos = pos2; q = "\"" }
            if (pos == 0) return ""
            rest = substr(s, pos + 1)
            pos = index(rest, q)
            if (pos == 0) return rest
            return substr(rest, 1, pos - 1)
        }
        function extract_id(s,   m, rest) {
            if (match(s, /(--id|\$menuentry_id_option)[[:space:]]+[\x27"][^\x27"]+[\x27"]/)) {
                rest = substr(s, RSTART, RLENGTH)
                return extract_first_quoted(rest)
            }
            if (match(s, /(--id|\$menuentry_id_option)[[:space:]]+[^[:space:]{]+/)) {
                rest = substr(s, RSTART, RLENGTH)
                sub(/^(--id|\$menuentry_id_option)[[:space:]]+/, "", rest)
                return rest
            }
            return ""
        }
        END {
            selector = (next_entry != "" ? next_entry : default_val)
            if (next_entry == "" && default_dynamic) {
                print "ERROR: dynamic GRUB default expression refused: " default_val > "/dev/stderr"
                exit 2
            }
            if (selector ~ />/) {
                print "ERROR: submenu selector refused (contains >): " selector > "/dev/stderr"
                exit 3
            }
            if (selector ~ /\$/) {
                print "ERROR: unresolved variable in GRUB selector refused: " selector > "/dev/stderr"
                exit 4
            }

            matched = -1
            if (selector ~ /^[0-9]+$/) {
                idx = selector + 0
                if (idx >= 0 && idx < item_idx) matched = idx
            } else {
                for (i = 0; i < item_idx; i++) {
                    if (item_id[i] == selector || item_title[i] == selector) {
                        if (matched != -1) {
                            print "ERROR: ambiguous GRUB selector matches multiple entries: " selector > "/dev/stderr"
                            exit 5
                        }
                        matched = i
                    }
                }
            }

            if (matched < 0) {
                print "ERROR: GRUB default selector did not match any top-level entry: " selector > "/dev/stderr"
                exit 6
            }
            if (item_kind[matched] != "menuentry") {
                print "ERROR: GRUB default selector resolves to submenu (refused): " selector > "/dev/stderr"
                exit 7
            }
            if (tolower(item_title[matched]) ~ /recovery/ || (" " item_linux[matched] " ") ~ /[[:space:]](single|recovery)[[:space:]]/) {
                print "ERROR: GRUB default entry is a recovery/single-user entry (refused): " item_title[matched] > "/dev/stderr"
                exit 8
            }
            if (item_linux_cnt[matched] != 1) {
                print "ERROR: GRUB default entry must have exactly 1 linux line (found " item_linux_cnt[matched] ")" > "/dev/stderr"
                exit 9
            }
            print item_linux[matched]
        }
    ' "$grub_cfg"
}

# ------------------------------------------------------------------------------
# Chrony configuration resolution, neutralisation, and recursive expansion
# (100% pure read-only helpers shared by 07_chrony_time_sync.sh & verify_07)
# ------------------------------------------------------------------------------
chrony_resolve_main_conf() {
    local exec_line=""
    exec_line="$("$HFT_SYSTEMCTL_CMD" show -p ExecStart --value chrony 2>/dev/null || true)"
    if [[ -z "$exec_line" ]]; then
        exec_line="$("$HFT_SYSTEMCTL_CMD" cat chrony 2>/dev/null | grep -E '^[[:space:]]*ExecStart=' | tail -n 1 || true)"
    fi
    local conf_path="/etc/chrony/chrony.conf"
    if [[ -n "$exec_line" ]]; then
        # Look for -f <path> in ExecStart arguments
        local custom
        custom="$(printf '%s\n' "$exec_line" | awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "-f" && (i + 1) <= NF) {
                    val = $(i + 1)
                    gsub(/[;,"'\'']/, "", val)
                    print val
                    exit
                }
            }
        }')"
        if [[ -n "$custom" ]]; then
            conf_path="$custom"
        fi
    fi
    if [[ -n "$HFT_ROOT" && "$conf_path" != "${HFT_ROOT}"* ]]; then
        printf '%s%s\n' "$HFT_ROOT" "$conf_path"
    else
        printf '%s\n' "$conf_path"
    fi
}

chrony_neutralise_main_conf_stdout() {
    local in_file="$1"
    awk '
        BEGIN {
            sentinel = "# HFT-NEUT: "
            inblock  = 0
            confdir_seen = 0
            n_neut = 0
        }
        /^# === BEGIN HFT chrony tuning/ { inblock = 1; next }
        /^# === END HFT chrony tuning/   { inblock = 0; next }
        inblock { next }
        {
            line = $0
            if (line ~ /^[[:space:]]*#[[:space:]]*HFT-NEUT:[[:space:]]?/) {
                sub(/^[[:space:]]*#[[:space:]]*HFT-NEUT:[[:space:]]?/, "", line)
            }
            if (line ~ /^[[:space:]]*confdir[[:space:]]+\/etc\/chrony\/conf\.d([[:space:]]|$)/) {
                confdir_seen = 1
                print line
                next
            }
            if (line ~ /^[[:space:]]*(server|pool|peer|refclock)[[:space:]]+/) {
                neut[n_neut++] = line
                print sentinel line
                next
            }
            if (line ~ /^[[:space:]]*sourcedir[[:space:]]+/) {
                path = $2
                if (path != "/etc/chrony/conf.d") {
                    neut[n_neut++] = line
                    print sentinel line
                    next
                }
            }
            print line
        }
        END {
            print "# === BEGIN HFT chrony tuning (managed by 07_chrony_time_sync.sh) ==="
            print "# Vendor/DHCP source directives have been neutralised in-place"
            print "# with a `# HFT-NEUT: ` sentinel prefix; replacements live in"
            print "# /etc/chrony/conf.d/07-hft.conf."
            if (n_neut > 0) {
                print "# Inventory of neutralised directives (informational only):"
                for (i = 0; i < n_neut; i++) print "#   - " neut[i]
            } else {
                print "# (No vendor directives needed neutralisation.)"
            }
            if (!confdir_seen) {
                print "# `confdir /etc/chrony/conf.d` was missing; injecting active directive:"
                print "confdir /etc/chrony/conf.d"
            }
            print "# === END HFT chrony tuning ==="
        }
    ' "$in_file"
}

# Recursively expand chrony include/confdir/sourcedir directives and emit normalized
# active source lines (server|pool|peer|refclock).
# Usage: chrony_expand_effective_sources <entry_file> [cand_dropin_path] [skip_colon_list]
chrony_expand_effective_sources() {
    local entry_file="$1"
    local cand_dropin="${2:-}"
    local skip_list="${3:-}"
    local dropin_logical="/etc/chrony/conf.d/07-hft.conf"

    declare -A _CHRONY_VISITED=()

    _chrony_map_path() {
        local p="$1"
        if [[ -n "$HFT_ROOT" && "$p" == /* && "$p" != "${HFT_ROOT}"* ]]; then
            printf '%s%s\n' "$HFT_ROOT" "$p"
        else
            printf '%s\n' "$p"
        fi
    }

    _chrony_is_skipped() {
        local p="$1"
        [[ -n "$skip_list" && ":${skip_list}:" == *":${p}:"* ]]
    }

    _chrony_walk() {
        local f="$1"
        [[ -r "$f" ]] || return 0
        if [[ -n "${_CHRONY_VISITED[$f]+x}" ]]; then
            return 0
        fi
        _CHRONY_VISITED["$f"]=1

        local line trimmed directive rest
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            [[ -z "$trimmed" || "$trimmed" == \#* || "$trimmed" == !* ]] && continue
            directive="${trimmed%%[[:space:]]*}"
            rest="${trimmed#"$directive"}"
            rest="$(printf '%s\n' "$rest" | sed -E 's/^[[:space:]]+//')"

            case "$directive" in
                server|pool|peer|refclock)
                    printf '%s\n' "$trimmed" | sed -E 's/[[:space:]]+/ /g'
                    ;;
                include)
                    local pat mapped_pat inc_f
                    for pat in $rest; do
                        mapped_pat="$(_chrony_map_path "$pat")"
                        shopt -s nullglob
                        for inc_f in $mapped_pat; do
                            [[ -f "$inc_f" ]] || continue
                            _chrony_is_skipped "$inc_f" && continue
                            if [[ -n "$cand_dropin" && "$inc_f" == "$(_chrony_map_path "$dropin_logical")" ]]; then
                                _chrony_walk "$cand_dropin"
                            else
                                _chrony_walk "$inc_f"
                            fi
                        done
                        shopt -u nullglob
                    done
                    ;;
                confdir)
                    local d mapped_d cf seen_cand=0
                    for d in $rest; do
                        mapped_d="$(_chrony_map_path "$d")"
                        if [[ -d "$mapped_d" ]]; then
                            shopt -s nullglob
                            for cf in "$mapped_d"/*.conf; do
                                [[ -f "$cf" ]] || continue
                                _chrony_is_skipped "$cf" && continue
                                if [[ -n "$cand_dropin" && "$cf" == "$(_chrony_map_path "$dropin_logical")" ]]; then
                                    seen_cand=1
                                    _chrony_walk "$cand_dropin"
                                else
                                    _chrony_walk "$cf"
                                fi
                            done
                            shopt -u nullglob
                        fi
                        if [[ -n "$cand_dropin" && "$d" == "/etc/chrony/conf.d" && "$seen_cand" -eq 0 ]]; then
                            _chrony_walk "$cand_dropin"
                        fi
                    done
                    ;;
                sourcedir)
                    local d mapped_d sf
                    for d in $rest; do
                        mapped_d="$(_chrony_map_path "$d")"
                        if [[ -d "$mapped_d" ]]; then
                            shopt -s nullglob
                            for sf in "$mapped_d"/*.sources; do
                                [[ -f "$sf" ]] || continue
                                _chrony_is_skipped "$sf" && continue
                                _chrony_walk "$sf"
                            done
                            shopt -u nullglob
                        fi
                    done
                    ;;
            esac
        done < "$f"
    }

    _chrony_walk "$entry_file"
}



