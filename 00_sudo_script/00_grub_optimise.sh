#!/usr/bin/env bash
set -euo pipefail

# Require GNU bash >= 4.3 (for associative arrays and `[[ -v arr[key] ]]`)
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: bash >= 4.3 is required (found ${BASH_VERSION})" >&2
    exit 1
fi

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<'EOF'
Usage: 00_grub_optimise.sh [options] [grub_file]

Options:
  -n, --dry-run             Preview topology detection and GRUB diff without sudo or writes
      --max-phys-cores <N>  Max physical cores to isolate starting at P1 (default: 3)
  -h, --help                Show this help message
EOF
}

# Parse CLI arguments (backward-compatible with positional [grub_file])
DRY_RUN=false
MAX_PHYS_CORES=3
GRUB_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --max-phys-cores)
            if [[ $# -lt 2 ]]; then
                echo "Error: --max-phys-cores requires a positive integer argument" >&2
                exit 1
            fi
            MAX_PHYS_CORES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -n "$GRUB_FILE" ]]; then
                echo "Error: unexpected extra positional argument: $1" >&2
                exit 1
            fi
            GRUB_FILE="$1"
            shift
            ;;
    esac
done

if [[ ! "$MAX_PHYS_CORES" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --max-phys-cores must be a positive integer (got '$MAX_PHYS_CORES')" >&2
    exit 1
fi

GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"

# Injectable paths / overrides (production defaults point to real host paths)
SYSFS_CPU_DIR="${HFT_GRUB_SYSFS_CPU_DIR:-/sys/devices/system/cpu}"
PCORE_CPUS_FILE="${HFT_GRUB_PCORE_CPUS_FILE:-/sys/devices/cpu_core/cpus}"
GRUB_D_DIR="${HFT_GRUB_D_DIR:-${GRUB_FILE}.d}"
SKIP_OS_CHECK="${HFT_GRUB_SKIP_OS_CHECK:-0}"
EC2_OVERRIDE="${HFT_GRUB_EC2_MODE:-}"
SUDO_CMD="${HFT_GRUB_SUDO:-sudo}"
UPDATE_GRUB_CMD="${HFT_GRUB_UPDATE_CMD:-update-grub}"

if [[ "$SKIP_OS_CHECK" == "1" && "$DRY_RUN" != true ]]; then
    echo "Error: HFT_GRUB_SKIP_OS_CHECK=1 is only allowed with --dry-run" >&2
    exit 1
fi

# Detect OS
is_linux() {
    [[ "$(uname -s)" == "Linux" ]]
}

is_ubuntu() {
    [[ -f /etc/os-release ]] && grep -qi "ubuntu" /etc/os-release
}

is_ec2() {
    if [[ "$EC2_OVERRIDE" == "1" ]]; then
        return 0
    elif [[ "$EC2_OVERRIDE" == "0" ]]; then
        return 1
    elif [[ -n "$EC2_OVERRIDE" ]]; then
        echo "Error: HFT_GRUB_EC2_MODE must be 0, 1, or empty (got '$EC2_OVERRIDE')" >&2
        exit 1
    fi
    [[ -f /sys/devices/virtual/dmi/id/board_asset_tag ]] && \
    grep -q "^i-" /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null
}

if [[ "$SKIP_OS_CHECK" != "1" ]]; then
    if ! is_linux; then
        echo "Error: This script only runs on Linux" >&2
        exit 1
    fi
    if ! is_ubuntu; then
        echo "Error: This script only supports Ubuntu" >&2
        exit 1
    fi
fi

# Detect environment
EC2_MODE=false
if is_ec2; then
    EC2_MODE=true
    echo "=== GRUB HFT Optimization Script (EC2 Mode) ==="
else
    echo "=== GRUB HFT Optimization Script (Non-EC2 Mode) ==="
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "(dry-run mode: no files will be modified)"
fi

# ------------------------------------------------------------------------------
# Strict Linux CPU-list parsing and range compression
# ------------------------------------------------------------------------------
parse_cpu_list() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/}"
    if [[ ! "$raw" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
        echo "Error: invalid CPU list format: '$raw'" >&2
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
                echo "Error: inverted CPU range '$part' in '$raw'" >&2
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
        echo "Error: empty CPU list to compress" >&2
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

# ------------------------------------------------------------------------------
# Step 1-4: Detect SMT/HT and physical-core topology from sysfs
# ------------------------------------------------------------------------------
if [[ ! -d "$SYSFS_CPU_DIR" ]]; then
    echo "Error: sysfs CPU directory not found: $SYSFS_CPU_DIR" >&2
    exit 1
fi

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

if (( ${#ONLINE_LIST[@]} == 0 )); then
    echo "Error: no online CPUs found under $SYSFS_CPU_DIR" >&2
    exit 1
fi

if (( ${#OFFLINE_LIST[@]} > 0 )) && [[ "$SMT_ACTIVE" != "0" ]]; then
    echo "Error: offline CPU(s) detected (${OFFLINE_LIST[*]}) while SMT is not cleanly disabled (smt/active=$SMT_ACTIVE); refusing to compute partial HT topology" >&2
    exit 1
fi

# Sort online CPU IDs numerically
mapfile -t ONLINE_LIST < <(printf '%s\n' "${ONLINE_LIST[@]}" | sort -nu)
TOTAL_LOGICAL="${#ONLINE_LIST[@]}"

declare -A PHYS_CORES=()
for cid in "${ONLINE_LIST[@]}"; do
    sib_file="$SYSFS_CPU_DIR/cpu${cid}/topology/thread_siblings_list"
    if [[ ! -r "$sib_file" ]]; then
        echo "Error: missing readable topology file: $sib_file" >&2
        exit 1
    fi
    sib_raw="$(tr -d '[:space:]' < "$sib_file")"
    mapfile -t sib_expanded < <(parse_cpu_list "$sib_raw")

    # Keep online CPUs only, sorted numerically and deduplicated
    declare -a sib_online=()
    for s in "${sib_expanded[@]}"; do
        if [[ -v "ONLINE_SET[$s]" ]]; then
            sib_online+=("$s")
        fi
    done
    if (( ${#sib_online[@]} == 0 )); then
        echo "Error: cpu${cid} has no online siblings in '$sib_raw'" >&2
        exit 1
    fi
    mapfile -t sib_online < <(printf '%s\n' "${sib_online[@]}" | sort -nu)

    # Assert cid itself is in its own sibling set
    found_self=false
    for s in "${sib_online[@]}"; do
        if (( s == cid )); then
            found_self=true
            break
        fi
    done
    if [[ "$found_self" != true ]]; then
        echo "Error: cpu${cid} not listed in its own thread_siblings_list ('$sib_raw')" >&2
        exit 1
    fi

    min_id="${sib_online[0]}"
    canon="${sib_online[*]}"
    if [[ -v "PHYS_CORES[$min_id]" && "${PHYS_CORES[$min_id]}" != "$canon" ]]; then
        echo "Error: inconsistent topology for physical core min_id=$min_id: '${PHYS_CORES[$min_id]}' vs '$canon'" >&2
        exit 1
    fi
    PHYS_CORES["$min_id"]="$canon"
done

mapfile -t P_KEYS < <(printf '%s\n' "${!PHYS_CORES[@]}" | sort -nu)
TOTAL_PHYS="${#P_KEYS[@]}"

# Assert P0 contains logical CPU 0 (aligned with irqaffinity=0)
P0_CPUS=" ${PHYS_CORES[${P_KEYS[0]}]} "
if [[ "$P0_CPUS" != *" 0 "* ]]; then
    echo "Error: physical core P0 (${PHYS_CORES[${P_KEYS[0]}]}) does not contain logical CPU 0" >&2
    exit 1
fi

# Detect HT/SMT
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
    echo "Error: Need at least 2 physical cores for isolation (found $TOTAL_PHYS physical core(s), $TOTAL_LOGICAL logical CPU(s))" >&2
    exit 1
fi

ISOLATE_PHYS_START=1
ISOLATE_PHYS_END=$(( TOTAL_PHYS - 1 ))
if (( ISOLATE_PHYS_END > MAX_PHYS_CORES )); then
    ISOLATE_PHYS_END="$MAX_PHYS_CORES"
fi

# Collect all logical CPUs belonging to target physical cores P[1..ISOLATE_PHYS_END]
declare -a TARGET_LOGICAL=()
for (( p = ISOLATE_PHYS_START; p <= ISOLATE_PHYS_END; p++ )); do
    pk="${P_KEYS[$p]}"
    read -ra _sibs <<< "${PHYS_CORES[$pk]}"
    for s in "${_sibs[@]}"; do
        TARGET_LOGICAL+=("$s")
    done
done
mapfile -t TARGET_LOGICAL < <(printf '%s\n' "${TARGET_LOGICAL[@]}" | sort -nu)

# Invariant: no logical CPU of P0 may enter the isolated list
for s in "${TARGET_LOGICAL[@]}"; do
    if [[ "$P0_CPUS" == *" $s "* ]]; then
        echo "Error: invariant violated — logical CPU $s belongs to physical core P0 and cannot be isolated" >&2
        exit 1
    fi
done

# Optional Intel hybrid P-core verification (/sys/devices/cpu_core/cpus)
if [[ -r "$PCORE_CPUS_FILE" ]]; then
    pcore_raw="$(tr -d '[:space:]' < "$PCORE_CPUS_FILE")"
    mapfile -t pcore_expanded < <(parse_cpu_list "$pcore_raw")
    declare -A PCORE_SET=()
    for pc in "${pcore_expanded[@]}"; do
        PCORE_SET["$pc"]=1
    done
    for s in "${TARGET_LOGICAL[@]}"; do
        if [[ ! -v "PCORE_SET[$s]" ]]; then
            echo "Error: target logical CPU $s is not in P-core mask '$pcore_raw' ($PCORE_CPUS_FILE)" >&2
            exit 1
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
    echo -e "${YELLOW}Note: SMT/HT is disabled (nosmt); re-run this script if SMT is re-enabled.${NC}"
fi
if [[ "$EC2_MODE" == true && "$HT_DETECTED" == true ]]; then
    echo -e "${YELLOW}Warning: EC2 mode with HT active uses idle=poll, which keeps idle HT siblings spinning. Consider disabling HT (ThreadsPerCore=1 or nosmt) on production EC2.${NC}"
fi
echo ""

# ------------------------------------------------------------------------------
# HFT kernel parameters (ordered key list for deterministic output)
# ------------------------------------------------------------------------------
declare -A HFT_PARAMS=()
declare -a HFT_PARAM_KEYS=()

if [[ "$EC2_MODE" == true ]]; then
    echo "Applying FULL optimization (EC2):"
    echo "  isolcpus, nohz_full, rcu_nocbs, irqaffinity, intel_pstate, processor.max_cstate, idle"
    HFT_PARAM_KEYS=(isolcpus nohz_full rcu_nocbs irqaffinity intel_pstate processor.max_cstate idle)
    HFT_PARAMS=(
        ["isolcpus"]="$ISOLATE_LIST"
        ["nohz_full"]="$ISOLATE_LIST"
        ["rcu_nocbs"]="$ISOLATE_LIST"
        ["irqaffinity"]="0"
        ["intel_pstate"]="disable"
        ["processor.max_cstate"]="0"
        ["idle"]="poll"
    )
else
    echo "Applying REDUCED optimization (non-EC2):"
    echo "  isolcpus, nohz_full, rcu_nocbs, irqaffinity"
    HFT_PARAM_KEYS=(isolcpus nohz_full rcu_nocbs irqaffinity)
    HFT_PARAMS=(
        ["isolcpus"]="$ISOLATE_LIST"
        ["nohz_full"]="$ISOLATE_LIST"
        ["rcu_nocbs"]="$ISOLATE_LIST"
        ["irqaffinity"]="0"
    )
fi
echo ""

# ------------------------------------------------------------------------------
# Step 5: Validate grub file and grub.d/*.cfg overrides (fail-closed)
# ------------------------------------------------------------------------------
if [[ ! -f "$GRUB_FILE" ]]; then
    echo "Error: $GRUB_FILE not found" >&2
    exit 1
fi

if [[ -d "$GRUB_D_DIR" ]]; then
    shopt -s nullglob
    for cfg in "$GRUB_D_DIR"/*.cfg; do
        if grep -Eq '^[[:space:]]*(GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX)=' "$cfg"; then
            echo "Error: $cfg overrides GRUB_CMDLINE_LINUX_DEFAULT/GRUB_CMDLINE_LINUX; remove or reconcile it before running this script" >&2
            exit 1
        fi
    done
    shopt -u nullglob
fi

BACKUP_FILE="${GRUB_FILE}.bak"
MODIFIED=false
DEFAULT_COUNT=0
declare -a CHANGES=()

update_cmdline_with_hft() {
    local original="$1"
    local -A parsed=()
    local result=""
    local -A handled=()

    local opt key val
    for opt in $original; do
        if [[ "$opt" == *"="* ]]; then
            key="${opt%%=*}"
            val="${opt#*=}"
            parsed["$key"]="$val"
        else
            parsed["$opt"]="__FLAG__"
        fi
    done

    for key in "${HFT_PARAM_KEYS[@]}"; do
        parsed["$key"]="${HFT_PARAMS[$key]}"
    done

    for opt in $original; do
        if [[ "$opt" == *"="* ]]; then
            key="${opt%%=*}"
        else
            key="$opt"
        fi

        [[ -v "handled[$key]" ]] && continue
        [[ ! -v "parsed[$key]" ]] && continue
        handled["$key"]=1

        if [[ "${parsed[$key]}" == "__FLAG__" ]]; then
            result="$result $key"
        else
            result="$result $key=${parsed[$key]}"
        fi
    done

    for key in "${HFT_PARAM_KEYS[@]}"; do
        if [[ ! -v "handled[$key]" ]]; then
            result="$result $key=${HFT_PARAMS[$key]}"
        fi
    done

    echo "$result" | sed 's/^ *//;s/ *$//'
}

remove_hft_from_cmdline() {
    local original="$1"
    local result=""
    local opt key

    for opt in $original; do
        if [[ "$opt" == *"="* ]]; then
            key="${opt%%=*}"
        else
            key="$opt"
        fi

        [[ -v "HFT_PARAMS[$key]" ]] && continue
        result="$result $opt"
    done

    echo "$result" | sed 's/^ *//;s/ *$//'
}

echo "Processing $GRUB_FILE..."
echo ""

TEMP_FILE="$(mktemp)"
trap 'rm -f /tmp/"$(basename "$TEMP_FILE")"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT= ]]; then
        DEFAULT_COUNT=$((DEFAULT_COUNT + 1))
        if (( DEFAULT_COUNT > 1 )); then
            echo "Error: duplicate GRUB_CMDLINE_LINUX_DEFAULT line in $GRUB_FILE" >&2
            exit 1
        fi
        if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"[[:space:]]*$ ]]; then
            old_value="${BASH_REMATCH[1]}"
        else
            echo "Error: malformed GRUB_CMDLINE_LINUX_DEFAULT line (expected double-quoted value): $line" >&2
            exit 1
        fi

        new_value="$(update_cmdline_with_hft "$old_value")"

        if [[ "$old_value" != "$new_value" ]]; then
            MODIFIED=true
            CHANGES+=("GRUB_CMDLINE_LINUX_DEFAULT:")
            CHANGES+=("  Old: \"$old_value\"")
            CHANGES+=("  New: \"$new_value\"")
        fi

        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"" >> "$TEMP_FILE"

    elif [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
        if [[ "$line" =~ ^GRUB_CMDLINE_LINUX=\"([^\"]*)\"[[:space:]]*$ ]]; then
            old_value="${BASH_REMATCH[1]}"
        else
            echo "Error: malformed GRUB_CMDLINE_LINUX line (expected double-quoted value): $line" >&2
            exit 1
        fi

        new_value="$(remove_hft_from_cmdline "$old_value")"

        if [[ "$old_value" != "$new_value" ]]; then
            MODIFIED=true
            CHANGES+=("GRUB_CMDLINE_LINUX (cleaned conflicts):")
            CHANGES+=("  Old: \"$old_value\"")
            CHANGES+=("  New: \"$new_value\"")
        fi

        echo "GRUB_CMDLINE_LINUX=\"$new_value\"" >> "$TEMP_FILE"

    elif [[ "$line" =~ ^#[[:space:]]*GRUB_CMDLINE_LINUX ]]; then
        echo "$line" >> "$TEMP_FILE"

    else
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$GRUB_FILE"

if (( DEFAULT_COUNT != 1 )); then
    echo "Error: GRUB_CMDLINE_LINUX_DEFAULT line missing in $GRUB_FILE" >&2
    exit 1
fi

if [[ "$MODIFIED" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}=== Dry-Run Diff (no files modified) ===${NC}"
        echo ""
        for change in "${CHANGES[@]}"; do
            echo -e "${BLUE}${change}${NC}"
        done
        exit 0
    fi

    if ! "$SUDO_CMD" -n true 2>/dev/null; then
        echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
        exit 1
    fi

    "$SUDO_CMD" cp "$GRUB_FILE" "$BACKUP_FILE"
    echo "Backup: $BACKUP_FILE"
    echo ""

    cat "$TEMP_FILE" | "$SUDO_CMD" tee "$GRUB_FILE" > /dev/null

    echo -e "${BLUE}=== GRUB Configuration Updated ===${NC}"
    echo ""
    for change in "${CHANGES[@]}"; do
        echo -e "${BLUE}${change}${NC}"
    done
    echo ""

    echo -e "${BLUE}Current GRUB_CMDLINE settings:${NC}"
    grep "^GRUB_CMDLINE" "$GRUB_FILE" | while read -r line; do
        echo -e "${BLUE}  $line${NC}"
    done
    echo ""

    echo "Running $UPDATE_GRUB_CMD..."
    if ! "$SUDO_CMD" "$UPDATE_GRUB_CMD"; then
        echo "Error: $UPDATE_GRUB_CMD failed; restoring $GRUB_FILE from $BACKUP_FILE" >&2
        "$SUDO_CMD" cp "$BACKUP_FILE" "$GRUB_FILE"
        exit 1
    fi
    echo ""

    echo -e "${GREEN}GRUB updated successfully. Changes will take effect after reboot.${NC}"
else
    echo -e "${GREEN}No changes needed. GRUB configuration is already optimized.${NC}"
fi
