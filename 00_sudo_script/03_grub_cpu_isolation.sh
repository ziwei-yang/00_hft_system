#!/usr/bin/env bash
# Layer 1 Step 03: Physical-core GRUB CPU isolation via pure POSIX sh drop-in
# (/etc/default/grub.d/99-hft-isolation.cfg) with 3-state rollback and next-boot verification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43

usage() {
    cat <<'EOF'
Usage: 03_grub_cpu_isolation.sh [options] [grub_file]

Options:
  -n, --dry-run             Preview topology detection and drop-in config without sudo or writes
      --max-phys-cores <N>  Max physical cores to isolate starting at P1 (default: 3)
      --enable-idle-poll    Explicitly add idle=poll (off by default)
      --no-managed-irq      Use isolcpus=<list> instead of isolcpus=domain,managed_irq,<list>
  -h, --help                Show this help message
EOF
}

DRY_RUN=false
MAX_PHYS_CORES=3
ENABLE_IDLE_POLL=false
NO_MANAGED_IRQ=false
GRUB_FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --max-phys-cores)
            [[ $# -ge 2 ]] || die "--max-phys-cores requires a positive integer argument"
            MAX_PHYS_CORES="$2"
            shift 2
            ;;
        --enable-idle-poll)
            ENABLE_IDLE_POLL=true
            shift
            ;;
        --no-managed-irq)
            NO_MANAGED_IRQ=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$GRUB_FILE_ARG" ]] || die "Unexpected extra positional argument: $1"
            GRUB_FILE_ARG="$1"
            shift
            ;;
    esac
done

if [[ ! "$MAX_PHYS_CORES" =~ ^[1-9][0-9]*$ ]]; then
    die "--max-phys-cores must be a positive integer (got '$MAX_PHYS_CORES')"
fi

# Backward-compatible injectable env overrides
if [[ -n "${HFT_GRUB_SKIP_OS_CHECK:-}" ]]; then
    HFT_SKIP_OS_CHECK="$HFT_GRUB_SKIP_OS_CHECK"
fi
if [[ -n "${HFT_GRUB_EC2_MODE:-}" ]]; then
    HFT_EC2_MODE="$HFT_GRUB_EC2_MODE"
fi
if [[ -n "${HFT_GRUB_SUDO:-}" ]]; then
    HFT_SUDO_CMD="$HFT_GRUB_SUDO"
fi
if [[ -n "${HFT_GRUB_UPDATE_CMD:-}" ]]; then
    HFT_UPDATE_GRUB_CMD="$HFT_GRUB_UPDATE_CMD"
fi

require_ubuntu

GRUB_FILE="${GRUB_FILE_ARG:-${HFT_GRUB_FILE:-${HFT_ROOT}/etc/default/grub}}"
GRUB_D_DIR="${HFT_GRUB_D_DIR:-${GRUB_FILE}.d}"
GRUB_CFG="${HFT_GRUB_CFG:-${HFT_ROOT}/boot/grub/grub.cfg}"
GRUB_ENV="${HFT_GRUB_ENV:-${HFT_ROOT}/boot/grub/grubenv}"
SYSFS_CPU_DIR="${HFT_GRUB_SYSFS_CPU_DIR:-${HFT_ROOT}/sys/devices/system/cpu}"
PCORE_CPUS_FILE="${HFT_GRUB_PCORE_CPUS_FILE:-${HFT_ROOT}/sys/devices/cpu_core/cpus}"
DROPIN_NAME="99-hft-isolation.cfg"
DROPIN_PATH="${GRUB_D_DIR}/${DROPIN_NAME}"

banner "Layer 1 Step 03: GRUB Physical-Core CPU Isolation"

# Run prerequisite pure read-only verifiers unless dry-run or isolated unit-test mode
if [[ "$DRY_RUN" != true && "${HFT_SKIP_PREREQS:-0}" != "1" ]]; then
    run_verify_chain --arg --staged -- "${SCRIPT_DIR}/verify_01_user_and_sudo.sh"
    run_verify_chain "${SCRIPT_DIR}/verify_02_base_packages_and_tz.sh"
fi

EC2_MODE=false
if is_ec2; then
    EC2_MODE=true
fi
VENDOR_ID="$(cpu_vendor_id)"
log_info "Environment: EC2_MODE=${EC2_MODE}, cpu_vendor=${VENDOR_ID}, dry_run=${DRY_RUN}"

# ------------------------------------------------------------------------------
# Physical-core topology detection & safety invariants
# ------------------------------------------------------------------------------
[[ -d "$SYSFS_CPU_DIR" ]] || die "sysfs CPU directory not found: $SYSFS_CPU_DIR"

SMT_ACTIVE="unknown"
if [[ -r "$SYSFS_CPU_DIR/smt/active" ]]; then
    SMT_ACTIVE="$(tr -d '[:space:]' < "$SYSFS_CPU_DIR/smt/active")"
fi

declare -A ONLINE_SET=()
declare -a ONLINE_LIST=()
declare -a OFFLINE_LIST=()

shopt -s nullglob
for cpu_dir in "$SYSFS_CPU_DIR"/cpu[0-9]*; do
    [[ -d "$cpu_dir" ]] || continue
    base="$(basename "$cpu_dir")"
    [[ "$base" =~ ^cpu([0-9]+)$ ]] || continue
    cid=$((10#${BASH_REMATCH[1]}))
    if [[ -r "$cpu_dir/online" ]]; then
        onl="$(tr -d '[:space:]' < "$cpu_dir/online")"
        if [[ "$onl" != "1" ]]; then
            OFFLINE_LIST+=("$cid")
            continue
        fi
    fi
    ONLINE_SET["$cid"]=1
    ONLINE_LIST+=("$cid")
done
shopt -u nullglob

(( ${#ONLINE_LIST[@]} > 0 )) || die "No online CPUs found under $SYSFS_CPU_DIR"

if (( ${#OFFLINE_LIST[@]} > 0 )) && [[ "$SMT_ACTIVE" != "0" ]]; then
    die "Offline CPU(s) detected (${OFFLINE_LIST[*]}) while SMT is not cleanly disabled (smt/active=$SMT_ACTIVE); refusing to compute partial HT topology."
fi

mapfile -t ONLINE_LIST < <(printf '%s\n' "${ONLINE_LIST[@]}" | sort -nu)
TOTAL_LOGICAL="${#ONLINE_LIST[@]}"

declare -A PHYS_CORES=()
for cid in "${ONLINE_LIST[@]}"; do
    sib_file="$SYSFS_CPU_DIR/cpu${cid}/topology/thread_siblings_list"
    [[ -r "$sib_file" ]] || die "Missing readable topology file: $sib_file"
    sib_raw="$(tr -d '[:space:]' < "$sib_file")"
    mapfile -t sib_expanded < <(parse_cpu_list "$sib_raw")

    declare -a sib_online=()
    for s in "${sib_expanded[@]}"; do
        if [[ -n "${ONLINE_SET[$s]+x}" ]]; then
            sib_online+=("$s")
        fi
    done
    (( ${#sib_online[@]} > 0 )) || die "cpu${cid} has no online siblings in '$sib_raw'"
    mapfile -t sib_online < <(printf '%s\n' "${sib_online[@]}" | sort -nu)

    found_self=false
    for s in "${sib_online[@]}"; do
        if (( s == cid )); then
            found_self=true
            break
        fi
    done
    [[ "$found_self" == true ]] || die "cpu${cid} not listed in its own thread_siblings_list ('$sib_raw')"

    min_id="${sib_online[0]}"
    canon="${sib_online[*]}"
    if [[ -n "${PHYS_CORES[$min_id]+x}" && "${PHYS_CORES[$min_id]}" != "$canon" ]]; then
        die "Inconsistent topology for physical core min_id=$min_id: '${PHYS_CORES[$min_id]}' vs '$canon'"
    fi
    PHYS_CORES["$min_id"]="$canon"
done

mapfile -t P_KEYS < <(printf '%s\n' "${!PHYS_CORES[@]}" | sort -nu)
TOTAL_PHYS="${#P_KEYS[@]}"

P0_CPUS=" ${PHYS_CORES[${P_KEYS[0]}]} "
if [[ "$P0_CPUS" != *" 0 "* ]]; then
    die "Physical core P0 (${PHYS_CORES[${P_KEYS[0]}]}) does not contain logical CPU 0"
fi

HT_DETECTED=false
if [[ "$SMT_ACTIVE" == "1" ]]; then
    HT_DETECTED=true
else
    for pk in "${P_KEYS[@]}"; do
        read -ra _sibs <<< "${PHYS_CORES[$pk]}"
        if (( ${#_sibs[@]} > 1 )); then
            HT_DETECTED=true
            break
        fi
    done
fi

if (( TOTAL_PHYS < 2 )); then
    die "Need at least 2 physical cores for isolation (found $TOTAL_PHYS physical core(s), $TOTAL_LOGICAL logical CPU(s))"
fi

ISOLATE_PHYS_START=1
ISOLATE_PHYS_END=$(( TOTAL_PHYS - 1 ))
if (( ISOLATE_PHYS_END > MAX_PHYS_CORES )); then
    ISOLATE_PHYS_END="$MAX_PHYS_CORES"
fi

declare -a TARGET_LOGICAL=()
for (( p = ISOLATE_PHYS_START; p <= ISOLATE_PHYS_END; p++ )); do
    pk="${P_KEYS[$p]}"
    read -ra _sibs <<< "${PHYS_CORES[$pk]}"
    for s in "${_sibs[@]}"; do
        TARGET_LOGICAL+=("$s")
    done
done
mapfile -t TARGET_LOGICAL < <(printf '%s\n' "${TARGET_LOGICAL[@]}" | sort -nu)

for s in "${TARGET_LOGICAL[@]}"; do
    if [[ "$P0_CPUS" == *" $s "* ]]; then
        die "Invariant violated: logical CPU $s belongs to P0 and cannot be isolated"
    fi
done

# Optional Intel hybrid P-core check
if [[ -r "$PCORE_CPUS_FILE" ]]; then
    pcore_raw="$(tr -d '[:space:]' < "$PCORE_CPUS_FILE")"
    mapfile -t pcore_expanded < <(parse_cpu_list "$pcore_raw")
    declare -A PCORE_SET=()
    for pc in "${pcore_expanded[@]}"; do
        PCORE_SET["$pc"]=1
    done
    for s in "${TARGET_LOGICAL[@]}"; do
        if [[ -z "${PCORE_SET[$s]+x}" ]]; then
            die "Target logical CPU $s is not in P-core mask '$pcore_raw' ($PCORE_CPUS_FILE)"
        fi
    done
    echo "P-core check: PASS (targets subset of $pcore_raw)"
fi

ISOLATE_LIST="$(compress_cpu_list "${TARGET_LOGICAL[@]}")"
echo "Detected $TOTAL_PHYS physical cores, $TOTAL_LOGICAL online logical CPUs (HT=$HT_DETECTED, smt/active=$SMT_ACTIVE)"
echo "  P0 (system/IRQ): logical [${PHYS_CORES[${P_KEYS[0]}]}]"
for (( p = ISOLATE_PHYS_START; p <= ISOLATE_PHYS_END; p++ )); do
    echo "  P${p} (isolated):   logical [${PHYS_CORES[${P_KEYS[$p]}]}]"
done
echo "Target isolation list (P${ISOLATE_PHYS_START}..P${ISOLATE_PHYS_END}): ${ISOLATE_LIST}"
if [[ "$SMT_ACTIVE" == "0" ]] && (( ${#OFFLINE_LIST[@]} > 0 )); then
    log_warn "SMT/HT is disabled (nosmt); re-run this script if SMT is re-enabled."
fi

# ------------------------------------------------------------------------------
# Build authoritative HFT parameter list
# ------------------------------------------------------------------------------
if [[ "$NO_MANAGED_IRQ" == true ]]; then
    ISOLCPUS_VAL="${ISOLATE_LIST}"
else
    ISOLCPUS_VAL="domain,managed_irq,${ISOLATE_LIST}"
fi

declare -a HFT_TOKENS=(
    "isolcpus=${ISOLCPUS_VAL}"
    "nohz_full=${ISOLATE_LIST}"
    "rcu_nocbs=${ISOLATE_LIST}"
    "irqaffinity=0"
)

if [[ "$EC2_MODE" == true && "$VENDOR_ID" == "GenuineIntel" ]]; then
    HFT_TOKENS+=("intel_pstate=disable")
fi
if [[ "$ENABLE_IDLE_POLL" == true ]]; then
    HFT_TOKENS+=("idle=poll")
fi

HFT_PARAM_STRING="${HFT_TOKENS[*]}"
log_info "Authoritative HFT kernel params: ${HFT_PARAM_STRING}"

# ------------------------------------------------------------------------------
# Validate /etc/default/grub and check for post-99 overrides in grub.d
# ------------------------------------------------------------------------------
[[ -f "$GRUB_FILE" ]] || die "$GRUB_FILE not found"

# Validate /etc/default/grub syntax via /bin/sh -n and single well-formed GRUB_CMDLINE_LINUX_DEFAULT
if ! /bin/sh -n "$GRUB_FILE" 2>/dev/null; then
    die "Malformed shell syntax in $GRUB_FILE"
fi
DEFAULT_COUNT=0
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT= ]]; then
        DEFAULT_COUNT=$((DEFAULT_COUNT + 1))
        if (( DEFAULT_COUNT > 1 )); then
            die "Duplicate GRUB_CMDLINE_LINUX_DEFAULT line in $GRUB_FILE"
        fi
        if [[ ! "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"[[:space:]]*$ ]]; then
            die "Malformed GRUB_CMDLINE_LINUX_DEFAULT line (expected double-quoted value): $line"
        fi
    fi
done < "$GRUB_FILE"
if (( DEFAULT_COUNT != 1 )); then
    die "GRUB_CMDLINE_LINUX_DEFAULT line missing in $GRUB_FILE"
fi

# Fail-closed if any *.cfg sorting AFTER 99-hft-isolation.cfg modifies GRUB_CMDLINE_LINUX*
if [[ -d "$GRUB_D_DIR" ]]; then
    shopt -s nullglob
    for cfg in "$GRUB_D_DIR"/*.cfg; do
        cfg_base="$(basename "$cfg")"
        if [[ "$cfg_base" > "$DROPIN_NAME" ]]; then
            if grep -Eq '^[[:space:]]*(GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX)=' "$cfg"; then
                die "Later override $cfg sorts after $DROPIN_NAME and modifies GRUB_CMDLINE_LINUX*; remove or reconcile it first."
            fi
        fi
    done
    shopt -u nullglob
fi

# Capture baseline preserved keys (console=, nvme_core.io_timeout=, root=) by sourcing /etc/default/grub + pre-99 grub.d/*.cfg in POSIX sh
BASELINE_CMDLINE="$(
    /bin/sh -c '
        set -e
        . "$1"
        if [ -d "$2" ]; then
            for f in "$2"/*.cfg; do
                [ -f "$f" ] || continue
                b="$(basename "$f")"
                [ "$b" = "99-hft-isolation.cfg" ] && continue
                case "$b" in
                    *)
                        if [ "$b" \< "99-hft-isolation.cfg" ]; then
                            . "$f"
                        fi
                        ;;
                esac
            done
        fi
        printf "%s %s\n" "${GRUB_CMDLINE_LINUX:-}" "${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    ' _ "$GRUB_FILE" "$GRUB_D_DIR"
)"

declare -a PRESERVE_TOKENS=()
for tok in $BASELINE_CMDLINE; do
    case "$tok" in
        console=*|nvme_core.io_timeout=*|root=*)
            PRESERVE_TOKENS+=("$tok")
            ;;
    esac
done

# Generate candidate pure POSIX sh drop-in file
TMP_DIR="$(mktemp -d /tmp/hft_grub_03.XXXXXX)"
cleanup_grub_tmp() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && safe_rm_tmp "$TMP_DIR" || true
}
trap cleanup_grub_tmp EXIT

CAND_DROPIN="${TMP_DIR}/${DROPIN_NAME}"
cat > "$CAND_DROPIN" <<EOF
# Managed by 03_grub_cpu_isolation.sh (pure POSIX sh)
# Expected isolated CPUs: ${ISOLATE_LIST}
# Expected HFT params: ${HFT_PARAM_STRING}
_hft_strip_keys() {
    _hft_out=""
    for _hft_tok in \$1; do
        case "\$_hft_tok" in
            isolcpus=*|nohz_full=*|rcu_nocbs=*|irqaffinity=*|intel_pstate=*|processor.max_cstate=*|idle=*)
                continue
                ;;
            *)
                _hft_out="\${_hft_out:+\$_hft_out }\$_hft_tok"
                ;;
        esac
    done
    printf '%s' "\$_hft_out"
}
GRUB_CMDLINE_LINUX="\$(_hft_strip_keys "\${GRUB_CMDLINE_LINUX:-}")"
_hft_clean_default="\$(_hft_strip_keys "\${GRUB_CMDLINE_LINUX_DEFAULT:-}")"
GRUB_CMDLINE_LINUX_DEFAULT="\${_hft_clean_default:+\${_hft_clean_default} }${HFT_PARAM_STRING}"
unset _hft_clean_default
EOF

# Validate pure POSIX sh syntax of candidate drop-in
if ! /bin/sh -n "$CAND_DROPIN"; then
    die "Generated drop-in failed POSIX /bin/sh syntax check!"
fi

# Verify candidate drop-in against effective grub.cfg validator
verify_grub_cfg_next_boot() {
    local cfg="$1"
    local envf="$2"
    if ! "$HFT_GRUB_SCRIPT_CHECK_CMD" "$cfg" >/dev/null 2>&1; then
        log_error "grub-script-check failed on $cfg"
        return 1
    fi
    local linux_args
    linux_args="$(grub_resolve_next_boot_linux_line "$cfg" "$envf")" || return 1

    # Check every expected HFT token is present
    local expected_tok tok key
    declare -A key_counts=()
    for tok in $linux_args; do
        if [[ "$tok" == *=* ]]; then
            key="${tok%%=*}"
        else
            key="$tok"
        fi
        case "$key" in
            isolcpus|nohz_full|rcu_nocbs|irqaffinity|intel_pstate|processor.max_cstate|idle)
                key_counts["$key"]=$(( ${key_counts[$key]:-0} + 1 ))
                ;;
        esac
    done

    for expected_tok in "${HFT_TOKENS[@]}"; do
        if [[ " $linux_args " != *" $expected_tok "* ]]; then
            log_error "Next-boot GRUB linux line missing expected param '$expected_tok' (got: $linux_args)"
            return 1
        fi
    done

    # Assert zero duplicate HFT keys
    for key in "${!key_counts[@]}"; do
        if (( key_counts["$key"] > 1 )); then
            log_error "Duplicate HFT key '$key' (${key_counts[$key]} times) in next-boot linux line: $linux_args"
            return 1
        fi
    done

    # Assert preserved baseline console= / nvme_core.io_timeout= / root= not dropped
    for tok in "${PRESERVE_TOKENS[@]}"; do
        if [[ " $linux_args " != *" $tok "* ]]; then
            log_error "Baseline kernel parameter '$tok' lost in next-boot linux line: $linux_args"
            return 1
        fi
    done

    return 0
}

# Check idempotency: drop-in unchanged AND existing grub.cfg already valid
NEEDS_CHANGE=true
if [[ -f "$DROPIN_PATH" ]] && cmp -s "$CAND_DROPIN" "$DROPIN_PATH"; then
    if [[ -f "$GRUB_CFG" ]] && verify_grub_cfg_next_boot "$GRUB_CFG" "$GRUB_ENV" >/dev/null 2>&1; then
        NEEDS_CHANGE=false
    fi
fi

if [[ "$NEEDS_CHANGE" == false ]]; then
    log_success "No changes needed. GRUB drop-in and next-boot grub.cfg are already up to date."
    exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "=== Dry-Run Preview: ${DROPIN_PATH} ==="
    cat "$CAND_DROPIN"
    echo "(dry-run mode: no files modified, no sudo invoked)"
    exit 0
fi

require_priv_ready
txn_init "03_grub_cpu_isolation"

# Save 3-state originals: GRUB_FILE, 99-hft-isolation.cfg (or absent), GRUB_CFG (or absent)
BAK_GRUB_FILE="${TMP_DIR}/grub.orig"
BAK_DROPIN="${TMP_DIR}/dropin.orig"
BAK_GRUB_CFG="${TMP_DIR}/grub.cfg.orig"
DROPIN_WAS_PRESENT=0
GRUB_CFG_WAS_PRESENT=0

cp -a "$GRUB_FILE" "$BAK_GRUB_FILE"
txn_record_file "$GRUB_FILE"
txn_record_file "$DROPIN_PATH"
txn_record_file "$GRUB_CFG"

if [[ -f "$DROPIN_PATH" ]]; then
    DROPIN_WAS_PRESENT=1
    cp -a "$DROPIN_PATH" "$BAK_DROPIN"
fi
if [[ -f "$GRUB_CFG" ]]; then
    GRUB_CFG_WAS_PRESENT=1
    cp -a "$GRUB_CFG" "$BAK_GRUB_CFG"
fi

restore_three_state() {
    log_error "Restoring 3-state GRUB originals..."
    run_priv cp -a "$BAK_GRUB_FILE" "$GRUB_FILE" || true
    if (( DROPIN_WAS_PRESENT == 1 )); then
        run_priv cp -a "$BAK_DROPIN" "$DROPIN_PATH" || true
    else
        safe_rm_file_priv "$DROPIN_PATH" || true
    fi
    if (( GRUB_CFG_WAS_PRESENT == 1 )); then
        run_priv cp -a "$BAK_GRUB_CFG" "$GRUB_CFG" || true
    else
        safe_rm_file_priv "$GRUB_CFG" || true
    fi
}

# Install pure POSIX sh drop-in
cat "$CAND_DROPIN" | atomic_write_priv "$DROPIN_PATH" 0644 0:0

log_info "Running $HFT_UPDATE_GRUB_CMD..."
if ! run_priv "$HFT_UPDATE_GRUB_CMD"; then
    log_error "$HFT_UPDATE_GRUB_CMD failed."
    restore_three_state
    exit 1
fi

if ! verify_grub_cfg_next_boot "$GRUB_CFG" "$GRUB_ENV"; then
    log_error "Post-update GRUB verification failed."
    restore_three_state
    exit 1
fi

# Record staged boot state ONLY when a change actually occurred
STAGED_STATE="${HFT_STATE_DIR}/grub_staged.state"
CUR_BOOT_ID="$(current_boot_id)"
atomic_write_priv "$STAGED_STATE" 0644 0:0 <<EOF
staged_boot_id=${CUR_BOOT_ID}
expected_isolated=${ISOLATE_LIST}
expected_hft_params=${HFT_PARAM_STRING}
EOF

# Self-verify in staged mode
HFT_GRUB_FILE="$GRUB_FILE" \
HFT_GRUB_D_DIR="$GRUB_D_DIR" \
HFT_GRUB_CFG="$GRUB_CFG" \
HFT_GRUB_ENV="$GRUB_ENV" \
    bash "${SCRIPT_DIR}/verify_03_grub_cpu_isolation.sh" --staged

log_success "GRUB CPU isolation staged (${HFT_PARAM_STRING}). Reboot required before running Layer 2 or --live checks."
