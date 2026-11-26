#!/usr/bin/env bash
# Layer 1 Step 07: Install and configure chrony for deterministic HFT time sync.
# - Candidate-first validation: validates neutralised config & recursive sources
#   BEFORE installing chrony or stopping systemd-timesyncd.
# - EC2 mode: exclusive Amazon Time Sync (169.254.169.123).
# - Bare-metal mode: Cloudflare anycast + NIST stratum-1 (non-smearing UTC).
# - Full transactional rollback of packages, configs, and services on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_priv_ready

banner "Layer 1 Step 07: Chrony Deterministic Time Sync"

# Prerequisite pure read-only verifiers
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"
run_verify_chain "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_04_irq_nic_and_perf.sh"
run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_05_memory_net_and_limits.sh"
run_verify_chain "${SCRIPT_DIR}/verify_06_disable_bg_noise.sh"

EC2_MODE=false
if is_ec2; then
    EC2_MODE=true
fi

DROPIN_PATH="${HFT_ROOT}/etc/chrony/conf.d/07-hft.conf"

dropin_canonical() {
    if [[ "$EC2_MODE" == true ]]; then
        cat <<'EOF'
# Managed by 07_chrony_time_sync.sh (EC2 mode) — do not edit by hand.
server 169.254.169.123 prefer iburst minpoll 2 maxpoll 4
EOF
    else
        cat <<'EOF'
# Managed by 07_chrony_time_sync.sh (Bare-metal mode) — do not edit by hand.
# Verified non-smearing UTC sources (Cloudflare anycast + NIST stratum-1).
pool   time.cloudflare.com  iburst minpoll 4 maxpoll 6 maxsources 2
server time-a-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-b-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-c-g.nist.gov    iburst minpoll 4 maxpoll 6
EOF
    fi
}

expected_sources_sorted() {
    dropin_canonical | awk '
        /^[[:space:]]*(server|pool|peer|refclock)[[:space:]]+/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/[[:space:]]+/, " ")
            print
        }
    ' | sort
}

TMP_WORK="$(mktemp -d /tmp/hft_chrony_07.XXXXXX)"
cleanup_chrony_tmp() {
    [[ -n "${TMP_WORK:-}" && -d "$TMP_WORK" ]] && safe_rm_tmp "$TMP_WORK" || true
}
trap cleanup_chrony_tmp EXIT

# ------------------------------------------------------------------------------
# Step 1: Capture pre-change state WITHOUT mutating packages or services
# ------------------------------------------------------------------------------
CHRONY_STATUS="$("$HFT_DPKG_CMD" -s chrony 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
CHRONY_INSTALLED=0
[[ "$CHRONY_STATUS" == "install ok installed" ]] && CHRONY_INSTALLED=1

TS_STATUS="$("$HFT_DPKG_CMD" -s systemd-timesyncd 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
TS_INSTALLED=0
[[ "$TS_STATUS" == "install ok installed" ]] && TS_INSTALLED=1

TS_UNIT_STATE="$(systemctl_state_pair systemd-timesyncd)"
CHRONY_UNIT_STATE="$(systemctl_state_pair chrony)"

MAIN_CONF=""
BASELINE_CONF_FILE=""
CACHED_CHRONY_DEB=""
CACHED_TS_DEB=""

if (( CHRONY_INSTALLED == 1 )); then
    MAIN_CONF="$(chrony_resolve_main_conf)"
    [[ -r "$MAIN_CONF" ]] || die "chrony is installed but main config $MAIN_CONF is not readable."
    BASELINE_CONF_FILE="$MAIN_CONF"
    log_info "Detected installed chrony; active main config: $MAIN_CONF"
else
    MAIN_CONF="${HFT_ROOT}/etc/chrony/chrony.conf"
    log_info "chrony not installed yet; staging .deb download for candidate validation..."
    PKG_DL_DIR="${TMP_WORK}/debs"
    EXTRACT_DIR="${TMP_WORK}/extract"
    mkdir -p "$PKG_DL_DIR" "$EXTRACT_DIR"

    if [[ -n "${HFT_CHRONY_DEB_PATH:-}" && -f "$HFT_CHRONY_DEB_PATH" ]]; then
        CACHED_CHRONY_DEB="$HFT_CHRONY_DEB_PATH"
    else
        (
            cd "$PKG_DL_DIR"
            "$HFT_APT_CMD" download chrony >/dev/null 2>&1 || run_priv "$HFT_APT_CMD" download chrony >/dev/null
        )
        shopt -s nullglob
        debs=("$PKG_DL_DIR"/chrony_*.deb "$PKG_DL_DIR"/chrony*.deb)
        shopt -u nullglob
        (( ${#debs[@]} > 0 )) || die "Failed to download chrony .deb package for candidate staging."
        CACHED_CHRONY_DEB="${debs[0]}"
    fi

    # Cache fallback systemd-timesyncd .deb if installed (for rollback if apt removes it)
    if (( TS_INSTALLED == 1 )); then
        if [[ -n "${HFT_TIMESYNCD_DEB_PATH:-}" && -f "$HFT_TIMESYNCD_DEB_PATH" ]]; then
            CACHED_TS_DEB="$HFT_TIMESYNCD_DEB_PATH"
        else
            (
                cd "$PKG_DL_DIR"
                "$HFT_APT_CMD" download systemd-timesyncd >/dev/null 2>&1 || true
            )
            shopt -s nullglob
            ts_debs=("$PKG_DL_DIR"/systemd-timesyncd*.deb)
            shopt -u nullglob
            (( ${#ts_debs[@]} > 0 )) && CACHED_TS_DEB="${ts_debs[0]}" || true
        fi
    fi

    "$HFT_DPKG_DEB_CMD" -x "$CACHED_CHRONY_DEB" "$EXTRACT_DIR"
    BASELINE_CONF_FILE="${EXTRACT_DIR}/etc/chrony/chrony.conf"
    [[ -r "$BASELINE_CONF_FILE" ]] || die "Extracted chrony package missing etc/chrony/chrony.conf"
fi

# ------------------------------------------------------------------------------
# Step 2: Generate candidate configs & validate recursively BEFORE any mutation
# ------------------------------------------------------------------------------
CAND_MAIN="${TMP_WORK}/chrony.conf.cand"
CAND_DROPIN="${TMP_WORK}/07-hft.conf.cand"

dropin_canonical > "$CAND_DROPIN"
chrony_neutralise_main_conf_stdout "$BASELINE_CONF_FILE" > "$CAND_MAIN"

# Identify existing extra drop-in/sources files under /etc/chrony/{conf.d,sources.d} to disable
declare -a PLANNED_DISABLE=()
SKIP_COLON_LIST=""
for extra_dir in "${HFT_ROOT}/etc/chrony/conf.d" "${HFT_ROOT}/etc/chrony/sources.d"; do
    [[ -d "$extra_dir" ]] || continue
    shopt -s nullglob
    for ef in "$extra_dir"/*.conf "$extra_dir"/*.sources; do
        [[ -f "$ef" ]] || continue
        [[ "$ef" == "$DROPIN_PATH" ]] && continue
        if grep -Eq '^[[:space:]]*(server|pool|peer|refclock)[[:space:]]+' "$ef"; then
            PLANNED_DISABLE+=("$ef")
            SKIP_COLON_LIST="${SKIP_COLON_LIST:+${SKIP_COLON_LIST}:}${ef}"
        fi
    done
    shopt -u nullglob
done

EXP_SOURCES="$(expected_sources_sorted)"
CAND_SOURCES="$(chrony_expand_effective_sources "$CAND_MAIN" "$CAND_DROPIN" "$SKIP_COLON_LIST" | sort)"

if [[ "$CAND_SOURCES" != "$EXP_SOURCES" ]]; then
    log_error "Candidate chrony effective sources do not match expected HFT sources (fail-closed BEFORE any package/service change)."
    log_error "Expected:"
    printf '%s\n' "$EXP_SOURCES" >&2
    log_error "Got:"
    printf '%s\n' "$CAND_SOURCES" >&2
    exit 1
fi
log_info "Candidate chrony config validated cleanly (zero extraneous sources)."

# ------------------------------------------------------------------------------
# Step 3: Transactional apply with automatic full rollback on any failure
# ------------------------------------------------------------------------------
txn_init "07_chrony_time_sync"
txn_record_kv unit_state "systemd-timesyncd" "$TS_UNIT_STATE"
txn_record_kv unit_state "chrony" "$CHRONY_UNIT_STATE"

# Persist fallback .deb into txn dir if available
TXN_TS_DEB=""
if [[ -n "$CACHED_TS_DEB" && -f "$CACHED_TS_DEB" ]]; then
    TXN_TS_DEB="${HFT_CURRENT_TXN_DIR}/files/systemd-timesyncd.deb"
    run_priv cp "$CACHED_TS_DEB" "$TXN_TS_DEB"
fi

rollback_and_die() {
    local msg="$1"
    log_error "$msg — rolling back chrony transaction..."
    txn_rollback || true
    exit 1
}

CHANGED=0

# Install chrony if not already installed
if (( CHRONY_INSTALLED == 0 )); then
    log_info "Installing chrony package..."
    if ! run_priv "$HFT_APT_CMD" update -qq || ! run_priv "$HFT_APT_CMD" install -y chrony; then
        rollback_and_die "Failed to install chrony package"
    fi
    txn_record_kv pkg_installed chrony "1"
    # Check if systemd-timesyncd was removed during chrony installation
    if (( TS_INSTALLED == 1 )); then
        ts_after="$("$HFT_DPKG_CMD" -s systemd-timesyncd 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
        if [[ "$ts_after" != "install ok installed" ]]; then
            txn_record_kv pkg_removed systemd-timesyncd "$TXN_TS_DEB"
        fi
    fi
    CHANGED=1
fi

# Record & write drop-in and neutralised main config
txn_record_file "$DROPIN_PATH"
txn_record_file "$MAIN_CONF"

if [[ ! -f "$DROPIN_PATH" ]] || ! cmp -s "$CAND_DROPIN" "$DROPIN_PATH"; then
    cat "$CAND_DROPIN" | atomic_write_priv "$DROPIN_PATH" 0644 0:0 || rollback_and_die "Failed writing $DROPIN_PATH"
    CHANGED=1
fi

if [[ ! -f "$MAIN_CONF" ]] || ! cmp -s "$CAND_MAIN" "$MAIN_CONF"; then
    cat "$CAND_MAIN" | atomic_write_priv "$MAIN_CONF" 0644 0:0 || rollback_and_die "Failed writing $MAIN_CONF"
    CHANGED=1
fi

# Disable extra source files found in conf.d / sources.d
for ef in "${PLANNED_DISABLE[@]}"; do
    txn_record_file "$ef"
    disabled_dst="${ef}.hft-disabled"
    txn_record_file "$disabled_dst"
    run_priv mv -f "$ef" "$disabled_dst" || rollback_and_die "Failed disabling extra chrony source file $ef"
    CHANGED=1
done

# Pre-start disk verification: re-expand from real disk paths and compare with candidate
DISK_SOURCES="$(chrony_expand_effective_sources "$MAIN_CONF" | sort)"
if [[ "$DISK_SOURCES" != "$CAND_SOURCES" ]]; then
    rollback_and_die "On-disk chrony expanded sources diverged from validated candidate"
fi

# Stop, disable, mask systemd-timesyncd
if [[ "${TS_UNIT_STATE#*:}" == "active" ]]; then
    run_priv "$HFT_SYSTEMCTL_CMD" stop systemd-timesyncd || rollback_and_die "Failed stopping systemd-timesyncd"
    CHANGED=1
fi
if [[ "${TS_UNIT_STATE%%:*}" != "masked" && "${TS_UNIT_STATE%%:*}" != "not-found" ]]; then
    run_priv "$HFT_SYSTEMCTL_CMD" disable systemd-timesyncd 2>/dev/null || true
    run_priv "$HFT_SYSTEMCTL_CMD" mask systemd-timesyncd || rollback_and_die "Failed masking systemd-timesyncd"
    CHANGED=1
fi

# Enable and start/restart chrony
if ! "$HFT_SYSTEMCTL_CMD" is-enabled --quiet chrony 2>/dev/null; then
    run_priv "$HFT_SYSTEMCTL_CMD" enable chrony || rollback_and_die "Failed enabling chrony"
    CHANGED=1
fi
if ! "$HFT_SYSTEMCTL_CMD" is-active --quiet chrony 2>/dev/null; then
    run_priv "$HFT_SYSTEMCTL_CMD" start chrony || rollback_and_die "Failed starting chrony"
    CHANGED=1
elif (( CHANGED == 1 )); then
    run_priv "$HFT_SYSTEMCTL_CMD" restart chrony || rollback_and_die "Failed restarting chrony"
fi

# Wait for convergence
log_info "Waiting for chrony sync (chronyc waitsync 60 0.05 10 1)..."
if ! "$HFT_CHRONYC_CMD" waitsync 60 0.05 10 1 >/dev/null; then
    rollback_and_die "chronyc waitsync did not converge within timeout"
fi

# Self-verify
if ! bash "${SCRIPT_DIR}/verify_07_chrony_time_sync.sh"; then
    rollback_and_die "verify_07_chrony_time_sync.sh failed"
fi

log_success "Layer 1 Step 07 complete."
